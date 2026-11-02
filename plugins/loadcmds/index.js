"use strict";
const KIND = { 0xc: "load", 0x80000018: "weak", 0x8000001f: "reexport", 0x20: "lazy", 0x80000023: "upward", 0x8000001c: "rpath" };
module.exports = {
  id: "loadcmds", name: "Load Commands", icon: "layers", version: "1.0", accepts: ["ipa"],
  description: "Architecture, whether the binary is still encrypted, and every library and run path it loads.",
  options: [{ key: "system", label: "Show system libraries", type: "bool", def: false }],
  async run({ blob, INJ, options, say }) {
    say("Reading the main binary…", 10);
    const entries = await INJ.zipList(blob), exe = INJ.pickExecutable(entries);
    if (!exe) throw new Error("No app executable found in this package.");
    const ab = await INJ.zipReadHead(blob, exe, 1048576), buf = ab && ab.buffer ? ab.buffer.slice(ab.byteOffset, ab.byteOffset + ab.byteLength) : ab;
    const info = INJ.listCommands(buf), sys = /^(\/usr\/lib\/|\/System\/)/;
    const rows = info.cmds.filter((c) => c.path && KIND[c.cmd]).map((c) => [KIND[c.cmd], c.path]).filter((r) => options.system || r[0] === "rpath" || !sys.test(r[1]));
    return {
      title: "Load commands",
      sections: [
        { title: "Binary", kind: "kv", rows: [["Architecture", (info.archs || [info.arch]).join(", ")], ["Encrypted (FairPlay)", info.cryptid ? "Yes: decrypt it first" : "No"], ["Load commands", String(info.ncmds)], ["Room for more", Math.max(0, info.free | 0) + " bytes"]] },
        { title: "Libraries and run paths (" + rows.length + ")", kind: "table", cols: ["Kind", "Path"], rows, note: options.system ? "" : "System libraries are hidden." },
      ],
    };
  },
};
