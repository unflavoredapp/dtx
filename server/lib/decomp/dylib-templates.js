'use strict';
// A small, fixed catalog of dylib starting points for someone who doesn't know how to describe what they want in
// code terms. A template is a structured prompt (not a code generator): required frameworks, the file layout to
// follow, a one-line hook approach, and a validation checklist that authored.js checks the written files against
// once the AI has actually written them (see TEMPLATES[x].checks, used by authored.js's validate()).
//   GET /api/staff/decomp/ai/dylib/templates -> { templates: [...] }  (catalog only, no project is touched)
const TEMPLATES = [
  {
    id: 'method-hook', name: 'Method hook', icon: 'arrow.triangle.swap',
    summary: 'Swizzle one method on an existing class to change or observe what it does.',
    frameworks: ['Foundation'], fileLayout: 'src/Hook.m (one file is usually enough)',
    hookApproach: 'In an __attribute__((constructor)) function: objc_getClass the target class, get the original Method with class_getInstanceMethod/class_getClassMethod, and swap it in with method_exchangeImplementations (or class_replaceMethod + imp_implementationWithBlock if the replacement needs to call the original by a renamed selector).',
    seedPrompt: 'I want a method-hook dylib. Target class: ___. Method to hook: ___ (instance or class method). What it should do differently: ___.',
    checks: [{ re: /method_exchangeImplementations|class_replaceMethod|imp_implementationWithBlock/, severity: 'warn', message: 'does not actually call a method-swizzling API (method_exchangeImplementations / class_replaceMethod) — check it really hooks anything' }],
  },
  {
    id: 'ui-overlay', name: 'UI overlay', icon: 'rectangle.on.rectangle',
    summary: 'Add a floating button, badge, or panel on top of the app\'s existing UI.',
    frameworks: ['Foundation', 'UIKit'], fileLayout: 'src/Overlay.m + src/OverlayView.m if the view is non-trivial',
    hookApproach: 'In the constructor, swizzle -[UIWindow makeKeyAndVisible] (or -[UIViewController viewDidAppear:]) once, and from there addSubview: your view to the key window so it survives view-controller changes underneath it.',
    seedPrompt: 'I want a UI overlay dylib. What it shows: ___. Where on screen: ___. What tapping it does: ___.',
    checks: [{ re: /addSubview|UIWindow|keyWindow/, severity: 'warn', message: 'does not reference UIWindow/addSubview — check it actually attaches a view to the screen' }],
  },
  {
    id: 'logger', name: 'Diagnostics logger', icon: 'terminal',
    summary: 'Log lifecycle events, method calls, or values to the console for debugging.',
    frameworks: ['Foundation'], fileLayout: 'src/Logger.m',
    hookApproach: 'Hook the methods you care about (applicationDidFinishLaunching, viewDidLoad, a specific method) the same way as the method-hook template, but the replacement calls the original IMP and NSLog()s before/after instead of changing behaviour.',
    seedPrompt: 'I want a logging dylib. What should it log: ___ (e.g. every call to a method, a value when it changes, app lifecycle events).',
    checks: [{ re: /NSLog|os_log/, severity: 'warn', message: 'does not call NSLog/os_log anywhere — a logger that does not log' }],
  },
  {
    id: 'settings-panel', name: 'Settings panel', icon: 'slider.horizontal.3',
    summary: 'Add a row or button that opens a small settings/info sheet with toggles or text.',
    frameworks: ['Foundation', 'UIKit'], fileLayout: 'src/SettingsEntry.m + src/SettingsSheet.m',
    hookApproach: 'Hook the app\'s existing settings table\'s -tableView:numberOfRowsInSection: and -cellForRowAtIndexPath: (or add a floating button, as in the UI-overlay template) that presents a UIAlertController or a small UIViewController modally with your controls; persist choices with NSUserDefaults.',
    seedPrompt: 'I want a settings-panel dylib. What it controls: ___. Where it should appear (its own button, or a new row in an existing settings screen): ___.',
    checks: [{ re: /UIAlertController|presentViewController|UIViewController/, severity: 'info', message: 'does not present any view controller or alert — confirm the panel actually opens something' }],
  },
  {
    id: 'blank', name: 'Blank / custom', icon: 'doc',
    summary: 'No scaffold — describe exactly what you want and let the AI design it from scratch.',
    frameworks: ['Foundation'], fileLayout: 'whatever the request needs', hookApproach: 'decided per request',
    seedPrompt: '', checks: [],
  },
];

function get(id) { return TEMPLATES.find((t) => t.id === id) || null; }

module.exports = function mountTemplates({ app, guard, B = '/api/staff/decomp' }) {
  app.get(`${B}/ai/dylib/templates`, guard, (req, res) => {
    res.json({ templates: TEMPLATES.map((t) => ({ id: t.id, name: t.name, icon: t.icon, summary: t.summary, frameworks: t.frameworks, fileLayout: t.fileLayout, hookApproach: t.hookApproach, seedPrompt: t.seedPrompt })) });
  });
};
module.exports.TEMPLATES = TEMPLATES;
module.exports.get = get;
