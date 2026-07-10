#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

function readArg(name, fallback = null) {
  const index = process.argv.indexOf(name);
  if (index === -1) {
    return fallback;
  }
  const value = process.argv[index + 1];
  if (!value || value.startsWith("--")) {
    throw new Error(`Missing value for ${name}.`);
  }
  return value;
}

const asarRoot = path.resolve(readArg("--root", "scratch/asar"));
const requestedAppVersion = readArg("--app-version", "");
const webviewRoot = path.join(asarRoot, "webview");
const assetsRoot = path.join(webviewRoot, "assets");
const buildRoot = path.join(asarRoot, ".vite", "build");

function assertDirectory(directoryPath) {
  if (
    !fs.existsSync(directoryPath) ||
    !fs.statSync(directoryPath).isDirectory()
  ) {
    throw new Error(`Expected directory: ${directoryPath}`);
  }
}

function readText(filePath) {
  return fs.readFileSync(filePath, "utf8");
}

function writeText(filePath, text) {
  fs.writeFileSync(filePath, text);
}

function countOccurrences(text, needle) {
  let count = 0;
  let index = -1;
  while ((index = text.indexOf(needle, index + 1)) !== -1) {
    count += 1;
  }
  return count;
}

function replaceOnce(filePath, before, after, label) {
  const text = readText(filePath);
  if (text.includes(after)) {
    console.log(`Already patched ${label}`);
    return;
  }

  const count = countOccurrences(text, before);
  if (count !== 1) {
    throw new Error(
      `Expected one match for ${label} in ${filePath}, found ${count}.`,
    );
  }

  writeText(filePath, text.replace(before, after));
  console.log(`Patched ${label}`);
}

function insertAfterOnce(filePath, anchor, insertion, marker, label) {
  const text = readText(filePath);
  if (text.includes(marker)) {
    console.log(`Already patched ${label}`);
    return;
  }

  const count = countOccurrences(text, anchor);
  if (count !== 1) {
    throw new Error(
      `Expected one anchor for ${label} in ${filePath}, found ${count}.`,
    );
  }

  writeText(filePath, text.replace(anchor, `${anchor}${insertion}`));
  console.log(`Patched ${label}`);
}

function insertBeforeOnce(filePath, anchor, insertion, marker, label) {
  const text = readText(filePath);
  if (text.includes(marker)) {
    console.log(`Already patched ${label}`);
    return;
  }

  const count = countOccurrences(text, anchor);
  if (count !== 1) {
    throw new Error(
      `Expected one anchor for ${label} in ${filePath}, found ${count}.`,
    );
  }

  writeText(filePath, text.replace(anchor, `${insertion}${anchor}`));
  console.log(`Patched ${label}`);
}

function removeCspMeta(filePath) {
  const text = readText(filePath);
  const marker = 'http-equiv="Content-Security-Policy"';
  const count = countOccurrences(text, marker);
  if (count === 0) {
    console.log("Already patched webview CSP metadata");
    return;
  }
  if (count !== 1) {
    throw new Error(
      `Expected at most one CSP meta tag in ${filePath}, found ${count}.`,
    );
  }

  const pattern =
    /\s*<meta(?=[^>]*http-equiv="Content-Security-Policy")[^>]*\/?>/;
  const matches = text.match(pattern);
  if (!matches || matches.length !== 1) {
    throw new Error(`Could not isolate the CSP meta tag in ${filePath}.`);
  }

  writeText(filePath, text.replace(pattern, ""));
  console.log("Patched webview CSP metadata");
}

function findFile(label, directoryPath, predicate, namePredicate = () => true) {
  const files = fs
    .readdirSync(directoryPath)
    .filter((name) => name.endsWith(".js") && namePredicate(name));
  const matches = files.filter((name) => {
    const filePath = path.join(directoryPath, name);
    return predicate(readText(filePath), name);
  });

  if (matches.length !== 1) {
    throw new Error(
      `Expected one file for ${label} under ${directoryPath}, found ${matches.length}: ${matches.join(", ")}`,
    );
  }

  return path.join(directoryPath, matches[0]);
}

function findAssetFile(label, predicate, namePattern = null) {
  return findFile(
    label,
    assetsRoot,
    predicate,
    namePattern == null ? undefined : (name) => namePattern.test(name),
  );
}

assertDirectory(asarRoot);
assertDirectory(webviewRoot);
assertDirectory(assetsRoot);
assertDirectory(buildRoot);

const desktopPackagePath = path.join(asarRoot, "package.json");
const desktopPackage = JSON.parse(readText(desktopPackagePath));
const desktopAppVersion = String(desktopPackage.version ?? "");
const desktopAppBrand = String(desktopPackage.codexAppBrand ?? "");
if (!desktopAppVersion) {
  throw new Error(`Expected a desktop version in ${desktopPackagePath}.`);
}
if (desktopAppBrand !== "chatgpt") {
  throw new Error(
    `Expected codexAppBrand=chatgpt in ${desktopPackagePath}, found ${desktopAppBrand || "<missing>"}.`,
  );
}
if (requestedAppVersion && requestedAppVersion !== desktopAppVersion) {
  throw new Error(
    `Requested ASAR version ${requestedAppVersion}, but ${desktopPackagePath} contains ${desktopAppVersion}.`,
  );
}

console.log(
  `Patching ChatGPT Desktop ASAR ${desktopAppVersion} (Electron ${desktopPackage.devDependencies?.electron ?? "unknown"}).`,
);

const indexHtmlPath = path.join(webviewRoot, "index.html");
const indexHtml = readText(indexHtmlPath);
const htmlEol = indexHtml.includes("\r\n") ? "\r\n" : "\n";
insertAfterOnce(
  indexHtmlPath,
  "    <!-- PROD_BASE_TAG_HERE -->",
  `${htmlEol}    <base href="/" />`,
  '<base href="/" />',
  "webview base URL",
);
insertAfterOnce(
  indexHtmlPath,
  "    <!-- PROD_CSP_TAG_HERE -->",
  `${htmlEol}    <script type="module" src="./assets/preload.js"></script>`,
  'src="./assets/preload.js"',
  "webview preload",
);
insertAfterOnce(
  indexHtmlPath,
  "    <title>Codex</title>",
  `${htmlEol}    <link rel="icon" type="image/svg+xml" href="./favicon.svg" />${htmlEol}    <link rel="manifest" href="/manifest.json" />`,
  'rel="manifest" href="/manifest.json"',
  "webview favicon and PWA manifest",
);
insertBeforeOnce(
  indexHtmlPath,
  '    <script type="module" crossorigin',
  `    <style>${htmlEol}      .main-surface {${htmlEol}        --spacing-token-safe-header-left: 0px;${htmlEol}      }${htmlEol}    </style>${htmlEol}`,
  "--spacing-token-safe-header-left: 0px",
  "webview safe-header style",
);
removeCspMeta(indexHtmlPath);

const routerPath = findAssetFile(
  "memory router",
  (text) =>
    text.includes(
      "function Fe({basename:e,children:t,initialEntries:n,initialIndex:r,unstable_useTransitions:i})",
    ) &&
    text.includes("v5Compat:!0") &&
    text.includes("I.useCallback"),
  /^development-.*\.js$/,
);
replaceOnce(
  routerPath,
  "a.current??=o({initialEntries:n,initialIndex:r,v5Compat:!0})",
  "a.current??=o({initialEntries:n??[window.__ELECTRON_SHIM__.initialRoute],initialIndex:r,v5Compat:!0})",
  "initial memory route",
);
replaceOnce(
  routerPath,
  "u=I.useCallback(e=>{i===!1?l(e):I.startTransition(()=>l(e))},[i])",
  "u=I.useCallback(e=>{window.__ELECTRON_SHIM__.onMemoryNavigationChanged(e),i===!1?l(e):I.startTransition(()=>l(e))},[i])",
  "memory navigation notification",
);

const appShellStatePath = findAssetFile(
  "app shell state",
  (text) =>
    text.includes("app-shell-bottom-panel-launcher-visible") &&
    text.includes("function $e(e,t,n={})"),
  /^app-shell-state-.*\.js$/,
);
replaceOnce(
  appShellStatePath,
  "z=s(a,!0)",
  "z=s(a,window.__ELECTRON_SHIM__.initialSidebarState)",
  "initial sidebar open state",
);
replaceOnce(
  appShellStatePath,
  "U=s(a,()=>new d(1))",
  "U=s(a,()=>new d(window.__ELECTRON_SHIM__.initialSidebarState))",
  "initial sidebar motion state",
);

const appShellPath = findAssetFile(
  "app shell close sidebar",
  (text) =>
    text.includes("function pa(e,t)") &&
    text.includes("p(`toggle-sidebar`,i,a)"),
  /^app-shell-.*\.js$/,
);
replaceOnce(
  appShellPath,
  "let i=r;yn(`toggleSidebar`,i);",
  "let i=r;window.__ELECTRON_SHIM__.closeSidebar=()=>{Ke(e,!1,{animate:t})};yn(`toggleSidebar`,i);",
  "electron shim closeSidebar",
);

const promptEditorPath = findAssetFile(
  "prompt editor",
  (text) =>
    text.includes("composer-suggestion-ui-event") &&
    text.includes("dispatchTransaction(e)"),
  /^prompt-editor-.*\.js$/,
);
replaceOnce(
  promptEditorPath,
  "f=new EventTarget,p=new Oa,m=s,h=new Pt(null,{attributes:{spellcheck:`true`},state:",
  "f=new EventTarget,p=new Oa,m=s,inputModeDisabled=!1,getAttributes=()=>inputModeDisabled?{spellcheck:`true`}:{spellcheck:`true`,inputmode:`none`},setPointerInputMode=e=>{inputModeDisabled!==e&&(inputModeDisabled=e,h.isDestroyed||h.setProps({attributes:getAttributes}))},h=new Pt(null,{attributes:getAttributes,state:",
  "prompt editor pointer input mode attributes",
);
replaceOnce(
  promptEditorPath,
  "dispatchTransaction(e){let t=h.state.apply(e);h.updateState(t),f.dispatchEvent(new CustomEvent(On,{detail:e.docChanged}))},handlePaste(e,t){",
  "dispatchTransaction(e){let t=h.state.apply(e);h.updateState(t),f.dispatchEvent(new CustomEvent(On,{detail:e.docChanged}))},handleDOMEvents:{mousedown(e,t){return setPointerInputMode(!0),!1},touchstart(e,t){return setPointerInputMode(!0),!1},blur(e,t){return setPointerInputMode(!1),!1}},handlePaste(e,t){",
  "prompt editor pointer input mode events",
);

const filesystemMediaPath = findAssetFile(
  "filesystem media source",
  (text) =>
    text.includes("s=`app://fs`,c=`/@fs`") &&
    text.includes("function a(e){return o(e)}"),
  /^filesystem-media-src-.*\.js$/,
);
replaceOnce(
  filesystemMediaPath,
  "function i(e){return`${s}${o(e)}`}",
  "function i(e){return o(e)}",
  "local file media source path",
);

const chatgptHomePath = findAssetFile(
  "ChatGPT home",
  (text) =>
    text.includes(
      "function QJ({announcementStorybookOverride:e,routeProjectId:t})",
    ) &&
    text.includes("Ae=i.formatMessage(jy.doAnything)") &&
    text.includes(
      "browserConversationId:re,composerLayoutMode:`auto-single-line`",
    ),
  /^app-main-.*\.js$/,
);
replaceOnce(
  chatgptHomePath,
  "m0={networkConfig:{api:l0,logEventUrl:w$,sdkExceptionUrl:u0,networkOverrideFunc:z1}}",
  "m0={overrideAdapter:window.__ELECTRON_SHIM__.overrideAdapter,networkConfig:{api:l0,logEventUrl:w$,sdkExceptionUrl:u0,networkOverrideFunc:z1}}",
  "Statsig override adapter",
);
replaceOnce(
  chatgptHomePath,
  "v=Hu(),y=NS(),b=qu(),x=b.state,{data:S}=ee(`account-info`",
  "v=Hu(),y=NS(),b=qu(),x=b.state,searchParamsPrompt=new URLSearchParams(b.search).get(`prompt`),{data:S}=ee(`account-info`",
  "home prompt query parameter",
);
replaceOnce(
  chatgptHomePath,
  "homeRunLocationRemoteProject:te,hideRunLocationDropdownOverride:!K,onLocalConversationCreated:Y,placeholderText:Ae",
  "homeRunLocationRemoteProject:te,hideRunLocationDropdownOverride:!K,defaultText:searchParamsPrompt??void 0,initialPrompt:searchParamsPrompt??void 0,onLocalConversationCreated:Y,placeholderText:Ae",
  "home composer prompt",
);
replaceOnce(
  chatgptHomePath,
  "browserConversationId:re,composerLayoutMode:`auto-single-line`,homeRunLocationRemoteProject:te,onLocalConversationCreated:Y",
  "browserConversationId:re,composerLayoutMode:`auto-single-line`,defaultText:searchParamsPrompt??void 0,initialPrompt:searchParamsPrompt??void 0,homeRunLocationRemoteProject:te,onLocalConversationCreated:Y",
  "home bottom composer prompt",
);

const rpcPath = findAssetFile(
  "app host RPC",
  (text) =>
    text.includes("type:`connect-app-host`") &&
    text.includes("async function $t()"),
  /^rpc-.*\.js$/,
);
replaceOnce(
  rpcPath,
  "Xt=new Yt({appActions:jt,appUpdates:Ft,downloads:qt})",
  "Xt=new Yt({appActions:jt,appUpdates:Ft,downloads:qt,requestUserInputAutoResolution:{recordConversationActivity:()=>undefined,setConversationPresented:()=>undefined,snooze:()=>undefined}})",
  "request user input auto-resolution service",
);
replaceOnce(
  rpcPath,
  "async function $t(){en=Qt(),tn=await en.services,tn.devboxService}",
  "async function $t(){if(window.__ELECTRON_SHIM__!=null){en=Xt,tn=Xt.services,tn.devboxService;return}en=Qt(),tn=await en.services,tn.devboxService}",
  "electron shim app host connection",
);

const chatgptLocalThreadPath = findAssetFile(
  "ChatGPT local conversation thread",
  (text) =>
    text.includes('from"./local-conversation-title-signals-') &&
    text.includes("function eC({conversationId:e,pendingWorktree:t") &&
    text.includes("re?.id==null||re.readAt!=null||ne(re.id)"),
  /^local-conversation-thread-.*\.js$/,
);
replaceOnce(
  chatgptLocalThreadPath,
  ",A=p(nr,e),j=p(wn,e),{firstVisibleTurnStartedAtMs:M,",
  ",A=p(nr,e),j=p(wn,e),codexHostedWindowTitle=p(Wi,e),{firstVisibleTurnStartedAtMs:M,",
  "conversation title signal read",
);
replaceOnce(
  chatgptLocalThreadPath,
  "(0,sC.useEffect)(()=>{re?.id==null||re.readAt!=null||ne(re.id)},[re?.id,re?.readAt,ne]);let oe=se(),",
  "(0,sC.useEffect)(()=>{re?.id==null||re.readAt!=null||ne(re.id)},[re?.id,re?.readAt,ne]);(0,sC.useEffect)(()=>{let t=codexHostedWindowTitle?.trim();t&&(document.title=`${t} | Codex`)},[codexHostedWindowTitle]);let oe=se(),",
  "browser document title sync",
);

const chatgptComposerPath = findAssetFile(
  "ChatGPT composer prompt plumbing",
  (text) =>
    text.includes(
      "function QH({aboveComposerHeaderContent:e,activeCollaborationMode:t,browserConversationId:n",
    ) &&
    text.includes("function bU(e){let t=(0,CU.c)(") &&
    text.includes("let He=hU,Ue=ec(") &&
    text.includes("Mn(`composer_prefill`)"),
  /^composer-.*\.js$/,
);
replaceOnce(
  chatgptComposerPath,
  "function bU(e){let t=(0,CU.c)(107)",
  "function bU(e){let t=(0,CU.c)(109)",
  "composer compiler cache size",
);
replaceOnce(
  chatgptComposerPath,
  "composerModeAvailability:d,placeholderText:f,composerLayoutMode:m,",
  "composerModeAvailability:d,placeholderText:f,initialPrompt,composerLayoutMode:m,",
  "inner composer initialPrompt prop",
);
replaceOnce(
  chatgptComposerPath,
  "cn&&cn!==wn.getText()&&wn.setPromptText(cn),",
  "cn&&cn!==wn.getText()?wn.setPromptText(cn):!cn&&initialPrompt!=null&&initialPrompt!==``&&wn.getText()===``?wn.setPromptText(initialPrompt):null,",
  "initial prompt empty-editor guard",
);
replaceOnce(
  chatgptComposerPath,
  "(0,tU.useEffect)(()=>{Fa()},[cn,ln,un,dn,Na]);",
  "(0,tU.useEffect)(()=>{Fa()},[cn,ln,un,dn,Na,initialPrompt]);",
  "initial prompt effect dependency",
);
replaceOnce(
  chatgptComposerPath,
  "composerModeAvailability:S,placeholderText:C,composerLayoutMode:w,",
  "composerModeAvailability:S,placeholderText:C,defaultText,initialPrompt,composerLayoutMode:w,",
  "outer composer prompt props",
);
replaceOnce(
  chatgptComposerPath,
  "let He=hU,Ue=ec(ie)?`prompt`:`plain`,We;",
  "let He=hU,Ue=ec(defaultText??ie)?`prompt`:`plain`,We;",
  "composer defaultText kind",
);
replaceOnce(
  chatgptComposerPath,
  "t[90]!==Ge||t[91]!==Ke||t[92]!==L||t[93]!==null?(qe=",
  "t[90]!==Ge||t[91]!==Ke||t[92]!==L||t[93]!==null||t[107]!==initialPrompt?(qe=",
  "inner composer memo dependency",
);
replaceOnce(
  chatgptComposerPath,
  "composerModeAvailability:S,placeholderText:C,composerLayoutMode:B,",
  "composerModeAvailability:S,placeholderText:C,initialPrompt,composerLayoutMode:B,",
  "inner composer prop forwarding",
);
replaceOnce(
  chatgptComposerPath,
  "t[91]=Ke,t[92]=L,t[93]=null,t[94]=qe)",
  "t[91]=Ke,t[92]=L,t[93]=null,t[107]=initialPrompt,t[94]=qe)",
  "inner composer memo assignment",
);
replaceOnce(
  chatgptComposerPath,
  "t[95]!==He||t[96]!==J||t[97]!==ie||t[98]!==Ue||t[99]!==We||t[100]!==qe?(Je=",
  "t[95]!==He||t[96]!==J||t[97]!==ie||t[98]!==Ue||t[99]!==We||t[100]!==qe||t[108]!==defaultText?(Je=",
  "composer provider memo dependency",
);
replaceOnce(
  chatgptComposerPath,
  "{defaultText:ie,defaultTextKind:Ue,children:[We,qe]}",
  "{defaultText:defaultText??ie,defaultTextKind:Ue,children:[We,qe]}",
  "composer provider defaultText",
);
replaceOnce(
  chatgptComposerPath,
  "t[99]=We,t[100]=qe,t[101]=Je)",
  "t[99]=We,t[100]=qe,t[108]=defaultText,t[101]=Je)",
  "composer provider memo assignment",
);

const workerPath = path.join(buildRoot, "worker.js");
replaceOnce(
  workerPath,
  "FD({dsn:sW,",
  "FD({enabled:!1,dsn:sW,",
  "worker Sentry disabled",
);

const sqlitePath = findFile(
  "SQLite shell Sentry",
  buildRoot,
  (text) =>
    text.includes("Lp(`bundle`,`electron`)") &&
    text.includes("child-process-gone") &&
    text.includes("render-process-gone"),
  (name) => /^sqlite-.*\.js$/.test(name),
);
replaceOnce(
  sqlitePath,
  "GB({dsn:t.Ji,",
  "GB({enabled:!1,dsn:t.Ji,",
  "SQLite shell Sentry disabled",
);

const sentryWebviewPath = findAssetFile(
  "webview Sentry",
  (text) =>
    text.includes("getSentryInitOptions") &&
    text.includes("bo(`bundle`,`webview`)"),
  /^error-boundary-.*\.js$/,
);
replaceOnce(
  sentryWebviewPath,
  "Kh({beforeSend:fe,dsn:p,environment:eg",
  "Kh({enabled:!1,beforeSend:fe,dsn:p,environment:eg",
  "webview Sentry disabled",
);

console.log(
  `Windows ChatGPT Desktop webview patches applied for ${desktopAppVersion}.`,
);
