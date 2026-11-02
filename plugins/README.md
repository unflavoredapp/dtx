# Plugins

Each plugin is a folder here with an `index.js`. The server loads them at start. Only the site's developer adds plugins.

```js
module.exports = {
  id: "my-tool",              // a-z, 0-9, dashes
  name: "My Tool", icon: "code", version: "1.0", accepts: ["ipa"],
  description: "One sentence.",
  options: [{ key: "filter", label: "Filter", type: "text", def: "" }],   // text | number | bool
  async run({ blob, path, INJ, options, say, cancelled }) {
    // blob: the IPA as a Blob; path: the same file on disk; INJ: zipList, zipRead, pickExecutable, listCommands, appMeta, …
    say("Working…", 40);                      // message and optional percent
    return { title: "Result", sections: [
      { title: "Details", kind: "kv", rows: [["Name", "value"]] },
      { title: "Things", kind: "list", items: ["a", "b"] },
      { title: "Table", kind: "table", cols: ["A", "B"], rows: [["1", "2"]] },
      { title: "Notes", kind: "text", text: "plain text" },
    ] };
  },
};
```

Output is shown as plain text. The server limits time per download, size, runs per hour and parallel jobs (`PLUGIN_JOBS`, `PLUGIN_IPA_MAX_MB`).
