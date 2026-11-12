// SPDX-License-Identifier: GPL-2.0-or-later
// Offline protocol regressions for the script sent to StikDebug and StikJIT.
// Run: node tests/test_henge_jit_script.js
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const script = fs.readFileSync(
  path.join(__dirname, "../ios/Henge/Resources/henge-jit.js"), "utf8"
);

function run(send) {
  const commands = [];
  const messages = [];
  let thrown = null;
  try {
  vm.runInNewContext(script, {
    get_pid: () => 1599,
    send_command: command => {
      commands.push(command);
      return send(command, commands);
    },
    log: (...parts) => messages.push(parts.map(String).join(" ")),
    prepare_memory_region: () => true
  }, { timeout: 1000 });
  } catch (error) {
    thrown = error;
  }
  return { commands, messages, thrown };
}

{
  const { commands, messages, thrown } = run(() => "E96");
  assert.deepEqual(commands, ["vAttach;63f"],
    "Must not continue a socket after vAttach refused the PID");
  assert(messages.some(line => line.includes("JIT_ATTACH_FAILED") && line.includes("E96")));
  assert(thrown && /JIT_ATTACH_FAILED/.test(thrown.message),
    "A refused attach must throw so the helper reports a failure, not a clean detach");
}
{
  const { commands, messages, thrown } = run(command => {
    if (command.startsWith("vAttach")) return "T05thread:1;";
    throw new Error("Socket NotConnected");
  });
  assert(thrown && /JIT_CONNECTION_LOST/.test(thrown.message), "A lost debugserver must throw");
  assert.deepEqual(commands, ["vAttach;63f", "c"]);
  assert(messages.some(line => line.includes("JIT_CONNECTION_LOST")));
}
{
  const stop = "T05thread:1;20:bc9a785634120000;10:0000000000000000;" +
    "00:0000000000000000;01:0000000000000000;";
  const { commands, messages, thrown } = run((command, calls) => {
    if (command.startsWith("vAttach")) return "T05thread:1;";
    if (command === "c") return calls.filter(x => x === "c").length === 1 ? stop : "E96";
    if (command.startsWith("m")) return "200d20d4"; // brk #0x69
    return "OK";
  });
  assert(commands.includes("m123456789abc,4"), "PC cannot be truncated to 40 bits");
  assert(commands.includes("P20=c09a785634120000;thread:1;"), "PC+4 must be 64-bit");
  assert(commands.includes("P0=e000006900000000;thread:1;"), "x0 must be 64-bit");
  assert(messages.some(line => line.includes("expected a stop packet")));
  assert(thrown && /expected a stop packet/.test(thrown.message));
}

{
  // A clean run (attach, one brk #0xf00d detach) must not throw.
  const stop = "T05thread:1;20:bc9a785634120000;10:0000000000000000;" +
    "00:0000000000000000;01:0000000000000000;";
  const { commands, thrown } = run(command => {
    if (command.startsWith("vAttach")) return "T05thread:1;";
    if (command === "c") return stop;
    if (command.startsWith("m")) return "a0013ed4"; // brk #0xf00d, x16 = 0: detach
    return "OK";
  });
  assert.equal(thrown, null, "A clean detach must not throw");
  assert(commands.includes("D"));
}

console.log("PASS: refused attach, lost socket, 64-bit registers, clean detach");
