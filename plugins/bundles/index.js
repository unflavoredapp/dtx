"use strict";
module.exports = {
  id: "bundles", name: "Frameworks & Dylibs", icon: "cube", version: "1.0", accepts: ["ipa"],
  description: "Every framework, dylib and app extension shipped inside the package.",
  async run({ blob, INJ, say }) {
    say("Listing the package…", 10);
    const entries = await INJ.zipList(blob), mb = (n) => (n >= 1048576 ? (n / 1048576).toFixed(1) + " MB" : Math.max(1, Math.round(n / 1024)) + " KB");
    const fw = {}, dy = [], ex = {};
    for (const e of entries) {
      const rel = e.name.replace(/^Payload\/[^/]+\.app\//, "");
      let m = /^(Frameworks\/[^/]+\.framework)\//.exec(rel); if (m) { fw[m[1]] = (fw[m[1]] || 0) + e.usize; continue; }
      m = /^(PlugIns\/[^/]+\.appex)\//.exec(rel); if (m) { ex[m[1]] = (ex[m[1]] || 0) + e.usize; continue; }
      if (/\.dylib$/i.test(rel)) dy.push([rel, mb(e.usize)]);
    }
    const rows = (o) => Object.keys(o).sort().map((k) => [k.split("/").pop(), mb(o[k])]);
    return {
      title: "Frameworks & dylibs",
      sections: [
        { title: "Frameworks (" + Object.keys(fw).length + ")", kind: "table", cols: ["Name", "Size"], rows: rows(fw) },
        { title: "Dylibs (" + dy.length + ")", kind: "table", cols: ["Path", "Size"], rows: dy.sort() },
        { title: "App extensions (" + Object.keys(ex).length + ")", kind: "table", cols: ["Name", "Size"], rows: rows(ex) },
      ],
    };
  },
};
