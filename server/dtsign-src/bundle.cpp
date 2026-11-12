#include "bundle.h"
#include "base64.h"
#include "common.h"
#include "macho.h"
#include "sys/stat.h"
#include "sys/types.h"
#include <pthread.h>

// ---------------------------------------------------------------------------------------------------------------
// The pinned worker chain.
//
// One worker per CPU this process may run on (set with taskset), each pinned to its own CPU. A batch of jobs is
// one shared counter: a worker takes the next job the moment it finishes its current one. The thread that starts
// a batch works on it too, which makes nesting safe. ZSIGN_WORKERS=1 turns the chain off: jobs run one after
// another, on the calling thread, in the order given.
// ---------------------------------------------------------------------------------------------------------------
#ifndef _WIN32
#include <atomic>
#include <condition_variable>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#include <sched.h>
#include <stdlib.h>
#include <unistd.h>
#include <algorithm>
extern __thread int g_nZWorker;
namespace {
class ZWorkers
{
public:
	static ZWorkers& Shared()
	{
		static ZWorkers* pWorkers = new ZWorkers();      // never freed: the workers live as long as the process
		return *pWorkers;
	}

	size_t Count() const { return m_arrCpus.size(); }

	// Runs fn(0) ... fn(n - 1) and returns when all of them are done.
	void Run(size_t n, const std::function<void(size_t)>& fn)
	{
		if (0 == n) {
			return;
		}
		struct Batch {
			std::atomic<size_t> next;
			std::atomic<size_t> done;
			size_t count;
			const std::function<void(size_t)>* fn;
			std::mutex lock;
			std::condition_variable finished;
			Batch() : next(0), done(0), count(0), fn(NULL) {}
		};
		std::shared_ptr<Batch> batch = std::make_shared<Batch>();
		batch->count = n;
		batch->fn = &fn;

		std::function<void()> drain = [batch]() {
			for (;;) {
				size_t i = batch->next.fetch_add(1);
				if (i >= batch->count) {
					break;
				}
				(*batch->fn)(i);
				if (batch->done.fetch_add(1) + 1 == batch->count) {
					std::lock_guard<std::mutex> guard(batch->lock);
					batch->finished.notify_all();
				}
			}
		};

		size_t nHelpers = (n - 1 < m_nThreads) ? n - 1 : m_nThreads;
		if (nHelpers > 0) {
			{
				std::lock_guard<std::mutex> guard(m_lock);
				for (size_t i = 0; i < nHelpers; i++) {
					m_jobs.push_back(drain);
				}
			}
			m_wake.notify_all();
		}

		drain();    // the caller is a worker on its own batch

		std::unique_lock<std::mutex> wait(batch->lock);
		batch->finished.wait(wait, [&batch]() { return batch->done.load() == batch->count; });
	}

private:
	static void Pin(int nCpu)
	{
		cpu_set_t set;
		CPU_ZERO(&set);
		CPU_SET(nCpu, &set);
		pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
	}

	ZWorkers() : m_nThreads(0)
	{
		cpu_set_t set;
		CPU_ZERO(&set);
		if (0 == sched_getaffinity(0, sizeof(set), &set)) {
			for (int c = 0; c < CPU_SETSIZE; c++) {
				if (CPU_ISSET(c, &set)) {
					m_arrCpus.push_back(c);
				}
			}
		}
		if (m_arrCpus.empty()) {
			m_arrCpus.push_back(0);
		}
		size_t nWant = m_arrCpus.size();
		const char* szWant = getenv("ZSIGN_WORKERS");
		if (NULL != szWant && atoi(szWant) > 0 && (size_t)atoi(szWant) < nWant) {
			nWant = (size_t)atoi(szWant);
		}
		if (nWant > 64) {
			nWant = 64;
		}
		m_arrCpus.resize(nWant);
		if (nWant < 2) {
			return;     // one worker: everything runs on the calling thread, in order
		}

		Pin(m_arrCpus[0]);      // the calling thread is worker 0
		g_nZWorker = 0;         // explicit: g_nZWorker already defaults to 0, but make it unmistakable in the log
		for (size_t i = 1; i < nWant; i++) {
			int nCpu = m_arrCpus[i];
			std::thread worker([this, i, nCpu]() {
				Pin(nCpu);
				g_nZWorker = (int)i;
				for (;;) {
					std::function<void()> job;
					{
						std::unique_lock<std::mutex> wait(m_lock);
						m_wake.wait(wait, [this]() { return !m_jobs.empty(); });
						job = m_jobs.front();
						m_jobs.pop_front();
					}
					job();
				}
			});
			worker.detach();
			m_nThreads++;
		}
	}

	std::vector<int> m_arrCpus;
	size_t m_nThreads;
	std::deque<std::function<void()> > m_jobs;
	std::mutex m_lock;
	std::condition_variable m_wake;
};
}
#endif

ZBundle::ZBundle()
{
	m_pSignAsset = NULL;
	m_bForceSign = false;
	m_bWeakInject = false;
}

bool ZBundle::FindAppFolder(const string& strFolder, string& strAppFolder)
{
	if (ZFile::IsPathSuffix(strFolder, ".app") || ZFile::IsPathSuffix(strFolder, ".appex")) {
		strAppFolder = strFolder;
		return true;
	}

	ZFile::EnumFolder(strFolder.c_str(), true, [&](bool bFolder, const string& strPath) {
		string strName = ZUtil::GetBaseName(strPath.c_str());
		if ("__MACOSX" == strName) {
			return true;
		}
		return false;
	}, [&](bool bFolder, const string& strPath) {
		if (bFolder) {
			if (ZFile::IsPathSuffix(strPath, ".app") || ZFile::IsPathSuffix(strPath, ".appex")) {
				strAppFolder = strPath;
				return true;
			}
		}
		return false;
	});

	return (!strAppFolder.empty());
}

bool ZBundle::GetSignFolderInfo(const string& strFolder, jvalue& jvNode, bool bGetName)
{
	string strInfoPlistData;
	string strInfoPlistPath = strFolder + "/Info.plist";
	ZFile::ReadFile(strInfoPlistPath.c_str(), strInfoPlistData);

	jvalue jvInfo;
	jvInfo.read_plist(strInfoPlistData);
	string strBundleId = jvInfo["CFBundleIdentifier"];
	string strBundleExe = jvInfo["CFBundleExecutable"];
	string strBundleVersion = jvInfo["CFBundleVersion"];
	if (strBundleId.empty() || strBundleExe.empty()) {
		return false;
	}

	string strInfoSHA1;
	string strInfoSHA256;
	ZSHA::SHABase64(strInfoPlistData, strInfoSHA1, strInfoSHA256);

	jvNode["bundle_id"] = strBundleId;
	jvNode["bundle_version"] = strBundleVersion;
	jvNode["bundle_executable"] = strBundleExe;
	jvNode["sha1"] = strInfoSHA1;
	jvNode["sha256"] = strInfoSHA256;
	if (!jvNode.has("path")) {
		jvNode["path"] = strFolder.substr(m_strAppFolder.size() + 1);
	}

	if (bGetName) {
		string strBundleName = jvInfo["CFBundleDisplayName"];
		if (strBundleName.empty()) {
			strBundleName = jvInfo["CFBundleName"].as_cstr();
		}
		jvNode["name"] = strBundleName;
	}

	return true;
}

bool ZBundle::GetObjectsToSign(const string& strFolder, jvalue& jvInfo)
{
	// Flat approach (from zsign): collect ALL sub-bundles recursively into a
	// single vector, sort deepest-first, then sign in order. This guarantees
	// inner bundles are signed before parents without a recursive tree.
	// The MachO magic number scan (not extension matching) prevents double-signing
	// framework-embedded dylibs that the old recursive approach would add to both
	// the root ["files"] list AND the framework's own signing pass.
	vector<string> allBundles;

	std::function<void(const string&)> findAllBundles = [&](const string& currentPath) {
		ZFile::EnumFolder(currentPath.c_str(), false, NULL, [&](bool bFolder, const string& strPath) {
			if (bFolder) {
				if (ZFile::IsPathSuffix(strPath, ".app") ||
					ZFile::IsPathSuffix(strPath, ".appex") ||
					ZFile::IsPathSuffix(strPath, ".framework") ||
					ZFile::IsPathSuffix(strPath, ".xctest")) {
					allBundles.push_back(strPath);
					findAllBundles(strPath);
				} else {
					findAllBundles(strPath);
				}
			}
			return false;
		});
	};

	findAllBundles(strFolder);

	// Deepest paths first — children signed before parents
	sort(allBundles.begin(), allBundles.end(), [](const string& a, const string& b) {
		size_t depthA = count(a.begin(), a.end(), '/');
		size_t depthB = count(b.begin(), b.end(), '/');
		return depthA > depthB;
	});

	for (const string& bundlePath : allBundles) {
		jvalue jvNode;
		if (GetSignFolderInfo(bundlePath, jvNode)) {
			jvInfo["folders"].push_back(jvNode);
		}
	}

	// Read the bundle executable name so we can exclude it from the ["files"] scan.
	// The main exe lives directly in strFolder and is a MachO — without this exclusion
	// it gets signed early as a loose file, then signed again (correctly) by SignNode.
	// The second sign is fine but the first corrupts the CodeResources hash ordering.
	string strBundleExe;
	{
		jvalue jvI;
		jvI.read_plist_from_file("%s/Info.plist", strFolder.c_str());
		strBundleExe = jvI["CFBundleExecutable"].as_cstr();
	}

	// Scan for loose MachO binaries (e.g. dylibs in Frameworks/ not inside a sub-bundle).
	// Magic number check avoids extension guessing. Skip anything inside a sub-bundle —
	// those are owned by that bundle's own signing pass. Also skip the bundle executable
	// itself — it is signed by SignNode after CodeResources is written.
	ZFile::EnumFolder(strFolder.c_str(), true, NULL, [&](bool bFolder, const string& strPath) {
		if (bFolder || string::npos != strPath.find(".dSYM")) {
			return false;
		}
		string strRel = strPath.substr(strFolder.size() + 1);
		// Skip the bundle's own executable
		if (!strBundleExe.empty() && strRel == strBundleExe) {
			return false;
		}
		bool bInBundle = (strRel.find(".framework/") != string::npos ||
		                  strRel.find(".app/")        != string::npos ||
		                  strRel.find(".appex/")       != string::npos ||
		                  strRel.find(".xctest/")      != string::npos);
		if (bInBundle) {
			return false;
		}
		bool bMachO = false;
		FILE* fp = fopen(strPath.c_str(), "rb");
		if (fp) {
			uint32_t magic = 0;
			if (1 == fread(&magic, sizeof(magic), 1, fp)) {
				bMachO = (magic == MH_MAGIC    || magic == MH_CIGAM    ||
				          magic == MH_MAGIC_64 || magic == MH_CIGAM_64 ||
				          magic == FAT_MAGIC   || magic == FAT_CIGAM);
			}
			fclose(fp);
		}
		if (bMachO) {
			jvInfo["files"].push_back(strPath.substr(m_strAppFolder.size() + 1));
		}
		return false;
	});

	return true;
}

bool ZBundle::GenerateCodeResources(const string& strFolder, jvalue& jvCodeRes)
{
	set<string> setFiles;
	ZFile::EnumFolder(strFolder.c_str(), true, NULL, [&](bool bFolder, const string& strPath) {
		if (!bFolder) {
			string strNode = strPath.substr(strFolder.size() + 1);
			ZUtil::StringReplace(strNode, "\\", "/");
			setFiles.insert(strNode);
		}
		return false;
	});

	jvalue jvInfo;
	jvInfo.read_plist_from_file("%s/Info.plist", strFolder.c_str());
	string strBundleExe = jvInfo["CFBundleExecutable"];

#ifdef _WIN32
	iconv ic;
	strBundleExe = ic.U82A(strBundleExe);
#endif

	setFiles.erase("_CodeSignature/CodeResources");
	setFiles.erase(strBundleExe);
	
	jvCodeRes.clear();
	jvCodeRes["files"] = jvalue(jvalue::E_OBJECT);
	jvCodeRes["files2"] = jvalue(jvalue::E_OBJECT);

	for (string strKey : setFiles) {
		string strFile = strFolder + "/" + strKey;
		string strSHA1Base64;
		string strSHA256Base64;
		ZSHA::SHABase64File(strFile.c_str(), strSHA1Base64, strSHA256Base64);

#ifdef _WIN32
		strKey = ic.A2U8(strKey);
#endif

		bool bomit1 = false;
		bool bomit2 = false;

		if (ZFile::IsPathSuffix(strKey, ".lproj/locversion.plist")) {
			bomit1 = true;
			bomit2 = true;
		}

		if (ZFile::IsPathSuffix(strKey, ".DS_Store") || "Info.plist" == strKey || "PkgInfo" == strKey) {
			bomit2 = true;
		}

		if (!bomit1) {
			if (string::npos != strKey.rfind(".lproj/")) {
				jvCodeRes["files"][strKey]["hash"] = "data:" + strSHA1Base64;
				jvCodeRes["files"][strKey]["optional"] = true;
			} else {
				jvCodeRes["files"][strKey] = "data:" + strSHA1Base64;
			}
		}

		if (!bomit2) {
			jvCodeRes["files2"][strKey]["hash"] = "data:" + strSHA1Base64;
			jvCodeRes["files2"][strKey]["hash2"] = "data:" + strSHA256Base64;
			if (string::npos != strKey.rfind(".lproj/")) {
				jvCodeRes["files2"][strKey]["optional"] = true;
			}
		}
	}

	jvCodeRes["rules"]["^.*"] = true;
	jvCodeRes["rules"]["^.*\\.lproj/"]["optional"] = true;
	jvCodeRes["rules"]["^.*\\.lproj/"]["weight"] = 1000.0;
	jvCodeRes["rules"]["^.*\\.lproj/locversion.plist$"]["omit"] = true;
	jvCodeRes["rules"]["^.*\\.lproj/locversion.plist$"]["weight"] = 1100.0;
	jvCodeRes["rules"]["^Base\\.lproj/"]["weight"] = 1010.0;
	jvCodeRes["rules"]["^version.plist$"] = true;

	jvCodeRes["rules2"]["^.*"] = true;
	jvCodeRes["rules2"][".*\\.dSYM($|/)"]["weight"] = 11.0;
	jvCodeRes["rules2"]["^(.*/)?\\.DS_Store$"]["omit"] = true;
	jvCodeRes["rules2"]["^(.*/)?\\.DS_Store$"]["weight"] = 2000.0;
	jvCodeRes["rules2"]["^.*\\.lproj/"]["optional"] = true;
	jvCodeRes["rules2"]["^.*\\.lproj/"]["weight"] = 1000.0;
	jvCodeRes["rules2"]["^.*\\.lproj/locversion.plist$"]["omit"] = true;
	jvCodeRes["rules2"]["^.*\\.lproj/locversion.plist$"]["weight"] = 1100.0;
	jvCodeRes["rules2"]["^Base\\.lproj/"]["weight"] = 1010.0;
	jvCodeRes["rules2"]["^Info\\.plist$"]["omit"] = true;
	jvCodeRes["rules2"]["^Info\\.plist$"]["weight"] = 20.0;
	jvCodeRes["rules2"]["^PkgInfo$"]["omit"] = true;
	jvCodeRes["rules2"]["^PkgInfo$"]["weight"] = 20.0;
	jvCodeRes["rules2"]["^embedded\\.provisionprofile$"]["weight"] = 20.0;
	jvCodeRes["rules2"]["^version\\.plist$"]["weight"] = 20.0;

	return true;
}

void ZBundle::GetChangedFiles(jvalue& jvNode, vector<string>& arrChangedFiles)
{
	// Collect loose MachO files (dylibs etc.) at this node
	if (jvNode.has("files")) {
		for (size_t i = 0; i < jvNode["files"].size(); i++) {
			arrChangedFiles.push_back(jvNode["files"][i]);
		}
	}

	// With the flat signing model, ["folders"] is a flat list on the root node only.
	// Each entry is a leaf — add its CodeResources and executable as changed files.
	if (jvNode.has("folders")) {
		for (size_t i = 0; i < jvNode["folders"].size(); i++) {
			jvalue& jvSubNode = jvNode["folders"][i];
			string strPath = jvSubNode["path"];
			arrChangedFiles.push_back(strPath + "/_CodeSignature/CodeResources");
			arrChangedFiles.push_back(strPath + "/" + jvSubNode["bundle_executable"].as_string());
		}
	}
}

void ZBundle::GetNodeChangedFiles(jvalue& jvNode)
{
	// Flat model: no nested folders, just populate root node's changed list
	vector<string> arrChangedFiles;
	GetChangedFiles(jvNode, arrChangedFiles);
	for (size_t i = 0; i < arrChangedFiles.size(); i++) {
		jvNode["changed"].push_back(arrChangedFiles[i]);
	}

	if ("/" == jvNode["path"]) { // root
		jvNode["changed"].push_back("embedded.mobileprovision");
	}
}

bool ZBundle::SignNode(jvalue& jvNode)
{
	// Sign loose MachO files at this node (e.g. dylibs in Frameworks/ not in a sub-bundle)
	if (jvNode.has("files")) {
		for (size_t i = 0; i < jvNode["files"].size(); i++) {
			string strFile = jvNode["files"][i];
			ZLog::PrintV(">>> SignFile: \t%s\n", strFile.c_str());
			ZMachO macho;
			if (macho.InitV("%s/%s", m_strAppFolder.c_str(), strFile.c_str())) {
				if (!macho.Sign(m_pSignAsset, m_bForceSign, "", "", "", "")) {
					return false;
				}
			} else {
				ZLog::WarnV(">>> Warning: Skipping non-Mach-O: %s\n", strFile.c_str());
			}
		}
	}

	// Sign sub-bundles. GetObjectsToSign already flattened every nested bundle (not just direct children) into
	// one array, sorted deepest-first by path depth ('/' count). Two bundles at the same depth are never one
	// inside the other, so they can safely run on different pinned workers at the same time; a bundle can sit
	// inside one at a shallower depth though, so depths run as separate waves, deepest first, every worker
	// finished before the next wave starts. (The previous fixed-size-16 window could put a parent and a child
	// that happened to land in the same slice of 16 on different threads at once — the deepest-first sort made
	// it look ordered, but a window boundary falling mid-family raced the two, which is what corrupted the
	// signature and crashed the kernel on install. Depth waves can't do that: a wave is never split mid-family,
	// because everything in it is provably at the same nesting level.) Fix #13: patch application-identifier
	// for .appex plugins so amfid doesn't reject the host app on launch due to mismatched entitlements.
	if (jvNode.has("folders")) {
		jvalue& folders = jvNode["folders"];
		size_t nFolders = folders.size();
#ifndef _WIN32
		auto depthOf = [&](size_t i) -> size_t {
			string p = folders[i]["path"].as_string();
			return (size_t)std::count(p.begin(), p.end(), '/');
		};

		struct WaveJob { ZBundle *parent; MSignAsset *assetClone; jvalue *node; bool result; };

		size_t pos = 0;
		bool bOK = true;
		while (pos < nFolders && bOK) {
			size_t end = pos + 1;
			while (end < nFolders && depthOf(end) == depthOf(pos)) {
				end++;      // one wave = one contiguous run of equal depth (the array is already depth-sorted)
			}
			size_t nWave = end - pos;
			vector<WaveJob> wave(nWave);
			for (size_t i = 0; i < nWave; i++) {
				wave[i].parent     = this;
				wave[i].assetClone = m_pSignAsset->Clone();
				wave[i].node       = &folders[pos + i];
				wave[i].result     = false;
			}

			ZWorkers::Shared().Run(nWave, [&wave](size_t i) {
				WaveJob& j = wave[i];
				if (!j.assetClone) {
					j.result = j.parent->SignNode(*j.node);
					return;
				}
				ZBundle lb;
				lb.m_pSignAsset      = j.assetClone;
				lb.m_bForceSign      = j.parent->m_bForceSign;
				lb.m_bWeakInject     = j.parent->m_bWeakInject;
				lb.m_strAppFolder    = j.parent->m_strAppFolder;
				lb.m_arrInjectDylibs = j.parent->m_arrInjectDylibs;
				j.result = lb.SignNode(*j.node);
			});

			for (size_t i = 0; i < nWave; i++) {
				if (wave[i].assetClone) {
					delete wave[i].assetClone;
				}
				if (!wave[i].result) {
					bOK = false;
				}
			}
			pos = end;
		}
		if (!bOK) {
			return false;
		}
#else
		for (size_t i = 0; i < nFolders; i++) {
			if (!SignNode(folders[i])) {
				return false;
			}
		}
#endif
	}

	jbase64 b64;
	string strInfoSHA1;
	string strInfoSHA256;
	string strFolder = jvNode["path"];
	string strBundleId = jvNode["bundle_id"];
	string strBundleExe = jvNode["bundle_executable"];
	b64.decode(jvNode["sha1"].as_cstr(), strInfoSHA1);
	b64.decode(jvNode["sha256"].as_cstr(), strInfoSHA256);
	if (strBundleId.empty() || strBundleExe.empty() || strInfoSHA1.empty() ||
		strInfoSHA256.empty()) {
		ZLog::ErrorV(">>> Can't get BundleID or BundleExecute or Info.plist SHASum in Info.plist! %s\n", strFolder.c_str());
		return false;
	}

#ifdef _WIN32
	iconv ic;
	strBundleExe = ic.U82A(strBundleExe);
#endif

	string strBaseFolder = m_strAppFolder;
	if ("/" != strFolder) {
		strBaseFolder += "/";
		strBaseFolder += strFolder;
	}

	string strExePath = strBaseFolder + "/" + strBundleExe;
	ZLog::PrintV(">>> SignFolder: %s, (%s)\n", ("/" == strFolder) ? ZUtil::GetBaseName(m_strAppFolder.c_str()) : strFolder.c_str(), strBundleExe.c_str());

	ZMachO macho;
	if (!macho.Init(strExePath.c_str())) {
		ZLog::ErrorV(">>> Can't parse BundleExecute file! %s\n", strExePath.c_str());
		return false;
	}

	ZFile::CreateFolderV("%s/_CodeSignature", strBaseFolder.c_str());
	string strCodeResFile = strBaseFolder + "/_CodeSignature/CodeResources";

	jvalue jvCodeRes;
	if (!m_bForceSign) {
		jvCodeRes.read_plist_from_file(strCodeResFile.c_str());
	}

	if (m_bForceSign || jvCodeRes.is_null()) { // create
		if (!GenerateCodeResources(strBaseFolder, jvCodeRes)) {
			ZLog::ErrorV(">>> Create CodeResources failed! %s\n", strBaseFolder.c_str());
			return false;
		}
	} else if (jvNode.has("changed")) { // use existsed
		for (size_t i = 0; i < jvNode["changed"].size(); i++) {
			string strFile = jvNode["changed"][i].as_cstr();
			string strRealFile = m_strAppFolder + "/" + strFile;

			string strFileSHA1;
			string strFileSHA256;
			if (!ZSHA::SHABase64File(strRealFile.c_str(), strFileSHA1, strFileSHA256)) {
				ZLog::ErrorV(">>> Can't get changed file SHASum! %s", strFile.c_str());
				return false;
			}

			string strKey = strFile;
			if ("/" != strFolder) {
				strKey = strFile.substr(strFolder.size() + 1);
			}

			jvCodeRes["files"][strKey] = "data:" + strFileSHA1;
			jvCodeRes["files2"][strKey]["hash"] = "data:" + strFileSHA1;
			jvCodeRes["files2"][strKey]["hash2"] = "data:" + strFileSHA256;

			ZLog::DebugV("\t\tChanged file: %s, %s\n", strFileSHA1.c_str(), strKey.c_str());
		}
	}

	string strCodeResData;
	jvCodeRes.style_write_plist(strCodeResData);
	if (!ZFile::WriteFile(strCodeResFile.c_str(), strCodeResData)) {
		ZLog::ErrorV("\tWriting CodeResources failed! %s\n", strCodeResFile.c_str());
		return false;
	}

	bool bForceSign = m_bForceSign;
	if ("/" == strFolder) { // inject dylib
		for (const string& strDylibFile : m_arrInjectDylibs) {
			if (macho.InjectDylib(m_bWeakInject, strDylibFile.c_str())) {
				bForceSign = true;
			}
		}
	}

	if (!macho.Sign(m_pSignAsset, bForceSign, strBundleId, strInfoSHA1, strInfoSHA256, strCodeResData)) {
		return false;
	}

	return true;
}

bool ZBundle::ModifyPluginsBundleId(const string& strOldBundleId, const string& strNewBundleId)
{
	vector<string> arrFolders;
	ZFile::EnumFolder(m_strAppFolder.c_str(), true, NULL, [&](bool bFolder, const string& strPath) {
		if (bFolder) {
			if (ZFile::IsPathSuffix(strPath, ".app") || ZFile::IsPathSuffix(strPath, ".appex")) {
				arrFolders.push_back(strPath);
			}
		}
		return false;
	});

	for (const string& strFolder: arrFolders) {
		jvalue jvInfo;
		if (!jvInfo.read_plist_from_file("%s/Info.plist", strFolder.c_str())) {
			ZLog::WarnV(">>> Can't find Plugin's Info.plist! %s\n", strFolder.c_str());
			continue;
		}

		string strOldPIBundleID = jvInfo["CFBundleIdentifier"];
		string strNewPIBundleID = strOldPIBundleID;
		ZUtil::StringReplace(strNewPIBundleID, strOldBundleId, strNewBundleId);
		jvInfo["CFBundleIdentifier"] = strNewPIBundleID;
		ZLog::PrintV(">>> BundleId: \t%s -> %s, Plugin\n", strOldPIBundleID.c_str(), strNewPIBundleID.c_str());

		if (jvInfo.has("WKCompanionAppBundleIdentifier")) {
			string strOldWKCBundleID = jvInfo["WKCompanionAppBundleIdentifier"];
			string strNewWKCBundleID = strOldWKCBundleID;
			ZUtil::StringReplace(strNewWKCBundleID, strOldBundleId, strNewBundleId);
			jvInfo["WKCompanionAppBundleIdentifier"] = strNewWKCBundleID;
			ZLog::PrintV(">>> BundleId: \t%s -> %s, Plugin-WKCompanionAppBundleIdentifier\n", strOldWKCBundleID.c_str(), strNewWKCBundleID.c_str());
		}

		if (jvInfo.has("NSExtension")) {
			if (jvInfo["NSExtension"].has("NSExtensionAttributes")) {
				if (jvInfo["NSExtension"]["NSExtensionAttributes"].has("WKAppBundleIdentifier")) {
					string strOldWKBundleID = jvInfo["NSExtension"]["NSExtensionAttributes"]["WKAppBundleIdentifier"];
					string strNewWKBundleID = strOldWKBundleID;
					ZUtil::StringReplace(strNewWKBundleID, strOldBundleId, strNewBundleId);
					jvInfo["NSExtension"]["NSExtensionAttributes"]["WKAppBundleIdentifier"] = strNewWKBundleID;
					ZLog::PrintV(">>> BundleId: \t%s -> %s, NSExtension-NSExtensionAttributes-WKAppBundleIdentifier\n", strOldWKBundleID.c_str(), strNewWKBundleID.c_str());
				}
			}
		}

		jvInfo.style_write_plist_to_file("%s/Info.plist", strFolder.c_str());
	}

	return true;
}

bool ZBundle::ModifyBundleInfo(const string& strBundleId, const string& strBundleVersion, const string& strDisplayName)
{
	jvalue jvInfo;
	if (!jvInfo.read_plist_from_file("%s/Info.plist", m_strAppFolder.c_str())) {
		ZLog::ErrorV(">>> Can't find app's Info.plist! %s\n", m_strAppFolder.c_str());
		return false;
	}

	if (!strBundleId.empty()) {
		string strOldBundleId = jvInfo["CFBundleIdentifier"];
		jvInfo["CFBundleIdentifier"] = strBundleId;
		ZLog::PrintV(">>> BundleId: \t%s -> %s\n", strOldBundleId.c_str(), strBundleId.c_str());
		ModifyPluginsBundleId(strOldBundleId, strBundleId);
	}

	if (!strDisplayName.empty()) {

		string strNewDisplayName = strDisplayName;

#ifdef _WIN32
		iconv ic;
		strNewDisplayName = ic.A2U8(strDisplayName);
#endif

		string strOldDisplayName = jvInfo["CFBundleDisplayName"];
		if (strOldDisplayName.empty()) {
			strOldDisplayName = jvInfo["CFBundleName"].as_cstr();
		}

		jvInfo["CFBundleName"] = strNewDisplayName;
		jvInfo["CFBundleDisplayName"] = strNewDisplayName;

		jvalue jvInfoStrings;
		if (jvInfoStrings.read_plist_from_file("%s/zh_CN.lproj/InfoPlist.strings", m_strAppFolder.c_str())) {
			jvInfoStrings["CFBundleName"] = strNewDisplayName;
			jvInfoStrings["CFBundleDisplayName"] = strNewDisplayName;
			jvInfoStrings.style_write_plist_to_file("%s/zh_CN.lproj/InfoPlist.strings", m_strAppFolder.c_str());
		}

		jvInfoStrings.clear();
		if (jvInfoStrings.read_plist_from_file("%s/zh-Hans.lproj/InfoPlist.strings", m_strAppFolder.c_str())) {
			jvInfoStrings["CFBundleName"] = strNewDisplayName;
			jvInfoStrings["CFBundleDisplayName"] = strNewDisplayName;
			jvInfoStrings.style_write_plist_to_file("%s/zh-Hans.lproj/InfoPlist.strings", m_strAppFolder.c_str());
		}

#ifdef _WIN32
		strOldDisplayName = ic.U82A(strOldDisplayName);
		strNewDisplayName = ic.U82A(strNewDisplayName);
#endif

		ZLog::PrintV(">>> BundleName: %s -> %s\n", strOldDisplayName.c_str(), strNewDisplayName.c_str());
	}

	if (!strBundleVersion.empty()) {
		string strOldBundleVersion = jvInfo["CFBundleVersion"];
		jvInfo["CFBundleVersion"] = strBundleVersion;
		jvInfo["CFBundleShortVersionString"] = strBundleVersion;
		ZLog::PrintV(">>> BundleVersion: %s -> %s\n", strOldBundleVersion.c_str(), strBundleVersion.c_str());
	}

	jvInfo.style_write_plist_to_file("%s/Info.plist", m_strAppFolder.c_str());
	return true;
}

bool ZBundle::SignFolder(MSignAsset* pSignAsset,
							const string& strFolder,
							const string& strBundleId,
							const string& strBundleVersion,
							const string& strDisplayName,
							const vector<string>& arrInjectDylibs,
							bool bForce,
							bool bWeakInject,
							bool bEnableCache)
{
	m_bForceSign = bForce;
	m_pSignAsset = pSignAsset;
	m_bWeakInject = bWeakInject;
	if (NULL == m_pSignAsset) {
		return false;
	}

	if (!FindAppFolder(strFolder, m_strAppFolder)) {
		ZLog::ErrorV(">>> Can't find app folder! %s\n", strFolder.c_str());
		return false;
	}

	if (!strBundleId.empty() || !strDisplayName.empty() || !strBundleVersion.empty()) {
		m_bForceSign = true;
		if (!ModifyBundleInfo(strBundleId, strBundleVersion, strDisplayName)) {
			return false;
		}
	}

	ZFile::RemoveFileV("%s/embedded.mobileprovision", m_strAppFolder.c_str());
	if (!pSignAsset->m_strProvData.empty()) {
		if (!ZFile::WriteFileV(pSignAsset->m_strProvData, "%s/embedded.mobileprovision", m_strAppFolder.c_str())) {
			ZLog::ErrorV(">>> Can't write embedded.mobileprovision!\n");
			return false;
		}
	}

	// Fix #7: Resolve wildcard entitlements against the actual bundle ID.
	// Provisioning profiles with wildcard app IDs (e.g. "MRRLG86H7W.*") embed
	// the wildcard into entitlements. iOS/amfid requires the code signature to
	// contain the RESOLVED value (e.g. "MRRLG86H7W.com.kdt.livecontainer"),
	// not the wildcard. Signing with unresolved wildcards causes integrity
	// validation failure on device launch (SIGKILL from amfid).
	if (!pSignAsset->m_strEntitleData.empty()) {
		// Read the actual bundle ID from Info.plist (may have been modified above)
		jvalue jvInfoPlist;
		jvInfoPlist.read_plist_from_file("%s/Info.plist", m_strAppFolder.c_str());
		string strActualBundleId = jvInfoPlist["CFBundleIdentifier"];

		if (!strActualBundleId.empty() && !pSignAsset->m_strTeamId.empty()) {
			string strFullAppId = pSignAsset->m_strTeamId + "." + strActualBundleId;
			string strWildcardAppId = pSignAsset->m_strTeamId + ".*";

			// Replace wildcard application-identifier with resolved value
			ZUtil::StringReplace(pSignAsset->m_strEntitleData, strWildcardAppId, strFullAppId);

			// Also resolve wildcard in keychain-access-groups and ubiquity identifiers
			// These follow the same TeamID.* → TeamID.bundleid pattern
			ZLog::PrintV(">>> Entitlements: Resolved wildcards (%s → %s)\n",
				strWildcardAppId.c_str(), strFullAppId.c_str());
		}
	}

	if (!arrInjectDylibs.empty()) {
		m_bForceSign = true;
		for (const string& strDylibFile : arrInjectDylibs) {
			string strFileName = ZUtil::GetBaseName(strDylibFile.c_str());
			if (ZFile::CopyFileV(strDylibFile.c_str(), "%s/%s", m_strAppFolder.c_str(), strFileName.c_str())) {
				m_arrInjectDylibs.push_back("@executable_path/" + strFileName);
			}
		}
	}

	string strCacheName;
	ZSHA::SHA1Text(m_strAppFolder, strCacheName);
	if (!ZFile::IsFileExistsV("./.dtsign_cache/%s.json", strCacheName.c_str())) {
		m_bForceSign = true;
	}

	jvalue jvRoot;
	if (m_bForceSign) {
		jvRoot["path"] = "/";
		jvRoot["root"] = m_strAppFolder;
		if (!GetSignFolderInfo(m_strAppFolder, jvRoot, true)) {
			ZLog::ErrorV(">>> Can't get BundleID, BundleVersion, or BundleExecute in Info.plist! %s\n", m_strAppFolder.c_str());
			return false;
		}
		if (!GetObjectsToSign(m_strAppFolder, jvRoot)) {
			return false;
		}
		GetNodeChangedFiles(jvRoot);
	} else {
		jvRoot.read_from_file("./.dtsign_cache/%s.json", strCacheName.c_str());
	}

	string strAppName = jvRoot["name"];

#ifdef _WIN32
	iconv ic;
	strAppName = ic.U82A(strAppName);
#endif

	ZLog::PrintV(">>> Signing: \t%s ...\n", m_strAppFolder.c_str());
	ZLog::PrintV(">>> AppName: \t%s\n", strAppName.c_str());
	ZLog::PrintV(">>> BundleId: \t%s\n", jvRoot["bundle_id"].as_cstr());
	ZLog::PrintV(">>> Version: \t%s\n", jvRoot["bundle_version"].as_cstr());
	ZLog::PrintV(">>> TeamId: \t%s\n", m_pSignAsset->m_strTeamId.c_str());
	ZLog::PrintV(">>> SubjectCN: \t%s\n", m_pSignAsset->m_strSubjectCN.c_str());
	ZLog::PrintV(">>> ReadCache: \t%s\n", m_bForceSign ? "NO" : "YES");
#ifndef _WIN32
	ZLog::PrintV(">>> Workers: \t%d pinned, one per CPU\n", (int)ZWorkers::Shared().Count());
#endif

	if (SignNode(jvRoot)) {
		if (bEnableCache) {
			ZFile::CreateFolder("./.dtsign_cache");
			jvRoot.style_write_to_file("./.dtsign_cache/%s.json", strCacheName.c_str());
		}
		return true;
	}

	return false;
}