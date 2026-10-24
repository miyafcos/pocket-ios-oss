// Offline behavior checks for the retained Web readers. No network calls.
import assert from "node:assert/strict";
import vm from "node:vm";
import { readFileSync } from "node:fs";
const guard = readFileSync(new URL("../Sources/WebReaderGuard.js", import.meta.url), "utf8");
const calls = [];
class XHR { open(...args) { calls.push(args); } }
class Form { submit() { assert.fail("form escaped"); } requestSubmit() { assert.fail("form escaped"); } }
const window = {fetch: async (...args) => { calls.push(args); return new Response("{}"); }};
let handler;
const context = {window, Request, DOMException, XMLHttpRequest: XHR, HTMLFormElement: Form,
  navigator: {sendBeacon() { assert.fail("beacon escaped"); }},
  document: {addEventListener(name, fn) { if(name === "submit") handler = fn; }}};
vm.runInNewContext(guard, context);
let checks = 0;
for(const path of ["talk/s/send","talk/s/ask","upload","reservations/r","fault","mail/send","quota/switch","launch","pad/a","term/s/key"]) {
  for(const method of ["POST","DELETE","PUT","PATCH"]) {
    await assert.rejects(window.fetch("/pocket/api/"+path,{method}),{name:"NotAllowedError"});
    assert.throws(() => new XHR().open(method,"/pocket/api/"+path),{name:"NotAllowedError"}); checks += 2;
  }
}
assert.equal(calls.length,0);
await window.fetch("/pocket/api/talk/s"); new XHR().open("GET","/pocket/api/health");
assert.equal(calls.length,2); checks++;
assert.throws(() => new Form().submit()); assert.throws(() => new Form().requestSubmit()); checks+=2;
assert.throws(() => new window.WebSocket("wss://example.invalid")); checks++;
assert.equal(context.navigator.sendBeacon(),false); checks++;
let prevented=false; handler({preventDefault(){prevented=true;}}); assert.equal(prevented,true); checks++;
console.log(`${checks} Web reader checks passed; network=false`);
