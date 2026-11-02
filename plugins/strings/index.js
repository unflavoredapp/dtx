"use strict";
module.exports = {
  id: "strings", name: "Strings", icon: "code", version: "1.0", accepts: ["ipa"],
  description: "Readable text found inside the main binary (URLs, keys, class names). Filter it to find what you need.",
  options: [{ key: "filter", label: "Only strings containing", type: "text", def: "" }, { key: "min", label: "Shortest string", type: "number", def: 8 }],
  async run({ blob, INJ, options, say, cancelled }) {
    say("Reading the main binary…", 10);
    const entries = await INJ.zipList(blob), exe = INJ.pickExecutable(entries);
    if (!exe) throw new Error("No app executable found in this package.");
    if (exe.usize > 400 * 1048576) throw new Error("This app's main binary is too large for this tool.");
    const u8 = new Uint8Array(await INJ.zipRead(blob, exe)), min = Math.max(4, Math.min(64, options.min | 0 || 8)), f = String(options.filter || "").toLowerCase(), out = [];
    let start = -1;
    for (let i = 0; i <= u8.length && out.length < 3000; i++) {
      const c = i < u8.length ? u8[i] : 0, ok = c >= 32 && c < 127;
      if (ok) { if (start < 0) start = i; continue; }
      if (start >= 0 && i - start >= min) {
        const s = Buffer.from(u8.subarray(start, Math.min(i, start + 300))).toString("latin1");
        if (!f || s.toLowerCase().includes(f)) out.push(s);
      }
      start = -1;
      if ((i & 0xfffff) === 0) { if (cancelled()) throw new Error("Cancelled."); say("Scanning…", Math.floor(10 + (i * 85) / u8.length)); }
    }
    return { title: "Strings", sections: [{ title: "Found (" + out.length + (out.length >= 3000 ? "+, showing the first 3000" : "") + ")", kind: "list", items: out }] };
  },
};
