"use strict";
module.exports = {
  id: "info", name: "App Info", icon: "info", version: "1.0", accepts: ["ipa"],
  description: "Name, bundle ID, version, minimum iOS and what is inside the package.",
  async run({ blob, INJ, say }) {
    say("Reading the package…", 10);
    const entries = await INJ.zipList(blob), exe = INJ.pickExecutable(entries);
    if (!exe) throw new Error("No app executable found in this package.");
    const m = await INJ.appMeta(blob, entries, exe, false), big = entries.slice().sort((a, b) => b.usize - a.usize).slice(0, 15);
    const mb = (n) => (n >= 1048576 ? (n / 1048576).toFixed(1) + " MB" : Math.max(1, Math.round(n / 1024)) + " KB");
    return {
      title: m.name || "App",
      sections: [
        { title: "App", kind: "kv", rows: [["Name", m.name], ["Bundle ID", m.bid], ["Version", m.ver], ["Build", m.build], ["Minimum iOS", m.minOS], ["Package size", mb(blob.size)], ["Files", String(entries.length)], ["Main binary", exe.name.split("/").pop() + " · " + mb(exe.usize)]] },
        { title: "Largest files", kind: "table", cols: ["File", "Size"], rows: big.map((e) => [e.name.replace(/^Payload\/[^/]+\.app\//, ""), mb(e.usize)]) },
      ],
    };
  },
};
