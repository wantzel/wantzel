// The extension contributes three tasks so that a .wz file can be built and run without
// each project writing its own tasks.json.
//
//   Wantzel: build         compile the file in front of you
//   Wantzel: run           compile it and run the result
//   Wantzel: build (all)   run the project's build.sh, if it has one
//
// Finding the compiler is the only interesting part. A checkout has it at bin/wantzel;
// anyone else has it on the PATH. The setting wantzel.compilerPath wins over both, so a
// project with an unusual layout needs one line rather than a task file.
const vscode = require("vscode");
const fs = require("fs");
const path = require("path");

const TYPE = "wantzel";

function compiler(folder, src) {
  const configured = vscode.workspace.getConfiguration("wantzel").get("compilerPath");
  if (configured) return configured.replace("${workspaceFolder}", folder?.uri.fsPath ?? "");

  // Walk up from the file being compiled, then from the workspace root, looking for
  // bin/wantzel. Checking the workspace root ALONE was too narrow: open a directory that
  // holds the checkout rather than being it -- wstack/ around wantzel/ -- and the compiler
  // sits one level down, so nothing was found and the build fell through to the PATH.
  const seen = new Set();
  for (const start of [src ? path.dirname(src) : null, folder?.uri.fsPath]) {
    let dir = start;
    while (dir && !seen.has(dir)) {
      seen.add(dir);
      const local = path.join(dir, "bin", "wantzel");
      if (fs.existsSync(local)) return local;
      const parent = path.dirname(dir);
      if (parent === dir) break;          // reached the root
      dir = parent;
    }
  }
  return "wantzel";                       // on the PATH
}

// A shell argument that survives a space in a path.
function q(s) {
  return /[^A-Za-z0-9_./:-]/.test(s) ? "'" + s.replace(/'/g, "'\\''") + "'" : s;
}

function makeTask(name, folder, commandLine, group) {
  const task = new vscode.Task(
    { type: TYPE, task: name },
    folder ?? vscode.TaskScope.Workspace,
    name,
    TYPE,
    new vscode.ShellExecution(commandLine),
    "$wantzel"                            // the matcher this extension contributes
  );
  if (group) task.group = group;
  task.presentationOptions = { reveal: vscode.TaskRevealKind.Silent, clear: true };
  return task;
}

function tasksFor(doc) {
  const out = [];
  if (!doc || doc.languageId !== TYPE) return out;

  const src = doc.uri.fsPath;
  const folder = vscode.workspace.getWorkspaceFolder(doc.uri);
  const wz = compiler(folder, src);
  // The binary goes beside the source, named after it. Predictable beats configurable
  // here: you can always see what a build produced.
  const bin = path.join(path.dirname(src), path.basename(src, ".wz"));

  out.push(makeTask("build", folder, `${q(wz)} ${q(src)} ${q(bin)}`, vscode.TaskGroup.Build));
  // Compile AND run: the && means a failed compile never runs a stale binary, which is
  // the whole reason this is one task rather than two.
  out.push(makeTask("run", folder, `${q(wz)} ${q(src)} ${q(bin)} && ${q(bin)}`));

  if (folder) {
    const buildsh = path.join(folder.uri.fsPath, "build.sh");
    if (fs.existsSync(buildsh)) {
      out.push(makeTask("build (all)", folder, `${q(buildsh)}`, vscode.TaskGroup.Build));
    }
  }
  return out;
}

function activate(context) {
  context.subscriptions.push(
    vscode.tasks.registerTaskProvider(TYPE, {
      provideTasks: () => tasksFor(vscode.window.activeTextEditor?.document),
      // A launch configuration names its preLaunchTask as a string ("wantzel: build"), and
      // VS Code then asks the provider to resolve it. Returning undefined here is what makes
      // Run Without Debugging fail with "could not find the task" -- so resolve it against
      // the file in front of you, the same way provideTasks does.
      resolveTask: (task) => {
        const name = task.definition?.task;
        if (!name) return undefined;
        return tasksFor(vscode.window.activeTextEditor?.document).find((t) => t.name === name);
      },
    })
  );

  // The two commands exist so the actions have a keybinding and a place in the palette.
  const run = (name) => async () => {
    const doc = vscode.window.activeTextEditor?.document;
    if (!doc || doc.languageId !== TYPE) {
      vscode.window.showErrorMessage("Wantzel: open a .wz file first.");
      return;
    }
    if (doc.isDirty) await doc.save();
    const task = tasksFor(doc).find((t) => t.name === name);
    if (task) await vscode.tasks.executeTask(task);
  };
  context.subscriptions.push(vscode.commands.registerCommand("wantzel.build", run("build")));
  context.subscriptions.push(vscode.commands.registerCommand("wantzel.run", run("run")));
}

function deactivate() {}

module.exports = { activate, deactivate };
