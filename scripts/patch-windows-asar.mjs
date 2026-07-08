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
const appVersion = readArg("--app-version", "");
const webviewRoot = path.join(asarRoot, "webview");
const assetsRoot = path.join(webviewRoot, "assets");

function assertDirectory(directoryPath) {
  if (!fs.existsSync(directoryPath) || !fs.statSync(directoryPath).isDirectory()) {
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
  if (text.includes(after) && !text.includes(before)) {
    console.log(`Already patched ${label}`);
    return;
  }

  const count = countOccurrences(text, before);
  if (count !== 1) {
    throw new Error(`Expected one match for ${label} in ${filePath}, found ${count}.`);
  }

  writeText(filePath, text.replace(before, after));
  console.log(`Patched ${label}`);
}

function findAssetFile(label, predicate) {
  const files = fs.readdirSync(assetsRoot).filter((name) => name.endsWith(".js"));
  const matches = files.filter((name) => {
    const filePath = path.join(assetsRoot, name);
    return predicate(readText(filePath), name);
  });

  if (matches.length !== 1) {
    throw new Error(
      `Expected one asset for ${label}, found ${matches.length}: ${matches.join(", ")}`,
    );
  }

  return path.join(assetsRoot, matches[0]);
}

assertDirectory(asarRoot);
assertDirectory(webviewRoot);
assertDirectory(assetsRoot);

const indexHtmlPath = path.join(webviewRoot, "index.html");
replaceOnce(
  indexHtmlPath,
  "    </style>\n    <script type=\"module\" crossorigin",
  "    </style>\n    <style>\n      .main-surface {\n        --spacing-token-safe-header-left: 0px;\n      }\n    </style>\n    <script type=\"module\" crossorigin",
  "webview safe-header style",
);

const appMainPath = findAssetFile(
  "app-main",
  (text) =>
    text.includes("function jP(e){let t=(0,MP.c)(3)") &&
    text.includes("networkConfig:{api:Iq"),
);
replaceOnce(
  appMainPath,
  "initialEntries:r,unstable_useTransitions:!1",
  "initialEntries:r??[window.__ELECTRON_SHIM__.initialRoute],unstable_useTransitions:!1",
  "initial memory route",
);
replaceOnce(
  appMainPath,
  "Vq={networkConfig:{api:Iq,logEventUrl:nK,sdkExceptionUrl:Lq,networkOverrideFunc:fq}}",
  "Vq={overrideAdapter:window.__ELECTRON_SHIM__.overrideAdapter,networkConfig:{api:Iq,logEventUrl:nK,sdkExceptionUrl:Lq,networkOverrideFunc:fq}}",
  "Statsig override adapter",
);
replaceOnce(
  appMainPath,
  "ke=r.formatMessage({id:`homePage.composer.placeholder.askAnything`,defaultMessage:`Do anything`,description:`Initial placeholder for the new home page composer`}),Ae=",
  "ke=r.formatMessage({id:`homePage.composer.placeholder.askAnything`,defaultMessage:`Do anything`,description:`Initial placeholder for the new home page composer`}),searchParamsPrompt=new URLSearchParams(window.location.search).get(`prompt`),Ae=",
  "home prompt query parameter",
);
replaceOnce(
  appMainPath,
  "showPlanKeywordSuggestion:!1,placeholderText:ke}):null",
  "showPlanKeywordSuggestion:!1,defaultText:searchParamsPrompt??void 0,placeholderText:ke}):null",
  "home composer prompt default",
);
replaceOnce(
  appMainPath,
  "showPlanKeywordSuggestion:!1,placeholderText:ke,surfaceClassName:`electron:dark:bg-token-side-bar-background`",
  "showPlanKeywordSuggestion:!1,defaultText:searchParamsPrompt??void 0,placeholderText:ke,surfaceClassName:`electron:dark:bg-token-side-bar-background`",
  "home bottom composer prompt default",
);

const routerPath = findAssetFile(
  "memory router",
  (text) =>
    text.includes("function o(e={}){let{initialEntries:t=[`/`]") &&
    text.includes("function Ct(e){"),
);
replaceOnce(
  routerPath,
  "r&&l&&l({action:s,location:n,delta:1})",
  "r&&l&&(window.__ELECTRON_SHIM__?.onMemoryNavigationChanged?.({action:s,location:n,delta:1}),l({action:s,location:n,delta:1}))",
  "memory router push notification",
);
replaceOnce(
  routerPath,
  "r&&l&&l({action:s,location:n,delta:0})",
  "r&&l&&(window.__ELECTRON_SHIM__?.onMemoryNavigationChanged?.({action:s,location:n,delta:0}),l({action:s,location:n,delta:0}))",
  "memory router replace notification",
);
replaceOnce(
  routerPath,
  "l&&l({action:s,location:n,delta:e})",
  "l&&(window.__ELECTRON_SHIM__?.onMemoryNavigationChanged?.({action:s,location:n,delta:e}),l({action:s,location:n,delta:e}))",
  "memory router pop notification",
);

const appShellStatePath = findAssetFile(
  "app shell state",
  (text) => text.includes("z=s(a,!0)") && text.includes("W=s(a,()=>new p(1))"),
);
replaceOnce(
  appShellStatePath,
  "z=s(a,!0)",
  "z=s(a,window.__ELECTRON_SHIM__?.initialSidebarState??!0)",
  "initial sidebar open state",
);
replaceOnce(
  appShellStatePath,
  "W=s(a,()=>new p(1))",
  "W=s(a,()=>new p(window.__ELECTRON_SHIM__?.initialSidebarState??!0))",
  "initial sidebar motion state",
);

const appShellPath = findAssetFile(
  "app shell close sidebar",
  (text) => text.includes("u(bn,`toggleSidebar`)") && text.includes("It(i,!1)"),
);
replaceOnce(
  appShellPath,
  "v=u(bn,`toggleSidebar`),y=u(bn,`navigateBack`),b=u(bn,`navigateForward`),x;",
  "v=u(bn,`toggleSidebar`),y=u(bn,`navigateBack`),b=u(bn,`navigateForward`),x;(window.__ELECTRON_SHIM__??={}).closeSidebar=()=>{It(c,!1)};",
  "electron shim closeSidebar",
);

const promptEditorPath = findAssetFile(
  "prompt editor",
  (text) =>
    text.includes("function td(e=null") &&
    text.includes("d=new EventTarget,f=new sd,p=o,m=new Cl(null,{attributes:{spellcheck:`true`},state:"),
);
replaceOnce(
  promptEditorPath,
  "d=new EventTarget,f=new sd,p=o,m=new Cl(null,{attributes:{spellcheck:`true`},state:",
  "d=new EventTarget,f=new sd,p=o,inputModeDisabled=!1,getAttributes=()=>inputModeDisabled?{spellcheck:`true`}:{spellcheck:`true`,inputmode:`none`},setPointerInputMode=e=>{inputModeDisabled!==e&&((inputModeDisabled=e),m.isDestroyed||m.setProps({attributes:getAttributes}))},m=new Cl(null,{attributes:getAttributes,state:",
  "prompt editor pointer input mode attributes",
);
replaceOnce(
  promptEditorPath,
  "dispatchTransaction(e){let t=m.state.apply(e);m.updateState(t),d.dispatchEvent(new Event(Rt))},handlePaste(e,t){",
  "dispatchTransaction(e){let t=m.state.apply(e);m.updateState(t),d.dispatchEvent(new Event(Rt))},handleDOMEvents:{mousedown(e,t){return setPointerInputMode(!0),!1},touchstart(e,t){return setPointerInputMode(!0),!1},blur(e,t){return setPointerInputMode(!1),!1}},handlePaste(e,t){",
  "prompt editor pointer input mode events",
);

const filesystemMediaPath = findAssetFile(
  "filesystem media src",
  (text) => text.includes("function i(e){return`${s}${o(e)}`}function a(e){return o(e)}"),
);
replaceOnce(
  filesystemMediaPath,
  "function i(e){return`${s}${o(e)}`}",
  "function i(e){return o(e)}",
  "local file media source path",
);

const rpcPath = findAssetFile(
  "app host RPC",
  (text) => text.includes("Gt=new Wt({appActions:Dt,appUpdates:jt,downloads:Ht})"),
);
replaceOnce(
  rpcPath,
  "Gt=new Wt({appActions:Dt,appUpdates:jt,downloads:Ht})",
  "Gt=new Wt({appActions:Dt,appUpdates:jt,downloads:Ht,requestUserInputAutoResolution:{recordConversationActivity:()=>undefined,setConversationPresented:()=>undefined,snooze:()=>undefined}})",
  "request user input auto-resolution service",
);
replaceOnce(
  rpcPath,
  "async function Jt(){$=qt(),Yt=await $.services}",
  "async function Jt(){if(window.__ELECTRON_SHIM__!=null){$=Gt,Yt=Gt.services;return}$=qt(),Yt=await $.services}",
  "electron shim app host connection",
);

const localThreadPath = findAssetFile(
  "local conversation thread",
  (text) =>
    text.includes("function US({conversationId:e") &&
    text.includes("from\"./local-conversation-title-signals-"),
);
replaceOnce(
  localThreadPath,
  ",O=m(hn,e),k=m(On,e),{conversationTurns:A,",
  ",O=m(hn,e),k=m(On,e),codexHostedWindowTitle=m(Si,e),{conversationTurns:A,",
  "conversation title signal read",
);
replaceOnce(
  localThreadPath,
  "(0,GS.useEffect)(()=>{W?.id==null||W.readAt!=null||re(W.id)},[W?.id,W?.readAt,re]);let oe=de(),",
  "(0,GS.useEffect)(()=>{W?.id==null||W.readAt!=null||re(W.id)},[W?.id,W?.readAt,re]);(0,GS.useEffect)(()=>{let t=codexHostedWindowTitle?.trim();t&&(document.title=`${t} | Codex`)},[codexHostedWindowTitle]);let oe=de(),",
  "browser document title sync",
);

const composerPath = findAssetFile(
  "composer default text",
  (text) =>
    text.includes("function KF(e){let t=(0,YF.c)(104)") &&
    text.includes("defaultText:W,defaultTextKind:Ye"),
);
replaceOnce(
  composerPath,
  "function KF(e){let t=(0,YF.c)(104)",
  "function KF(e){let t=(0,YF.c)(106)",
  "composer compiler cache size",
);
replaceOnce(
  composerPath,
  "localWorkspaceMaterialization:j,onCreateSideConversation:M}=e,N=o===void 0",
  "localWorkspaceMaterialization:j,onCreateSideConversation:M,defaultText:codexWebDefaultText}=e,N=o===void 0",
  "composer defaultText prop",
);
replaceOnce(
  composerPath,
  "let Je=VF,Ye=us(W)?`prompt`:`plain`,Xe;",
  "let Je=VF,Ye=us(codexWebDefaultText??W)?`prompt`:`plain`,Xe;",
  "composer defaultText kind",
);
replaceOnce(
  composerPath,
  "t[92]!==Je||t[93]!==ue||t[94]!==W||t[95]!==Ye||t[96]!==Xe||t[97]!==$e?(et=(0,ZF.jsxs)(Je,{defaultText:W,defaultTextKind:Ye,children:[Xe,$e]},ue),t[92]=Je,t[93]=ue,t[94]=W,t[95]=Ye,t[96]=Xe,t[97]=$e,t[98]=et):et=t[98];",
  "t[92]!==Je||t[93]!==ue||t[94]!==W||t[95]!==Ye||t[96]!==Xe||t[97]!==$e||t[104]!==codexWebDefaultText?(et=(0,ZF.jsxs)(Je,{defaultText:codexWebDefaultText??W,defaultTextKind:Ye,children:[Xe,$e]},ue),t[92]=Je,t[93]=ue,t[94]=W,t[95]=Ye,t[96]=Xe,t[97]=$e,t[104]=codexWebDefaultText,t[98]=et):et=t[98];",
  "composer defaultText provider",
);

const sentryWebviewPath = findAssetFile(
  "webview Sentry init",
  (text) => text.includes("Kh({beforeSend:fe,dsn:p,environment:eg"),
);
replaceOnce(
  sentryWebviewPath,
  "Kh({beforeSend:fe,dsn:p,environment:eg",
  "Kh({enabled:!1,beforeSend:fe,dsn:p,environment:eg",
  "webview Sentry disabled",
);

console.log(
  `Windows Codex Desktop webview patches applied${appVersion ? ` for ${appVersion}` : ""}.`,
);
