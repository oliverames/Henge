// henge-jit.js against a scripted debugserver: a stop that is not a brk goes back to the thread as a signal, a brk still runs its command.
// Run with jsc from the repo root.
function le32(v) { return [0, 8, 16, 24].map(s => ((v >>> s) & 0xff).toString(16).padStart(2, '0')).join(''); }
function le64(v) { return Array.from({ length: 8 }, (_, i) => Number((BigInt(v) >> BigInt(8 * i)) & 0xffn).toString(16).padStart(2, '0')).join(''); }
function stop(sig, pc) {
    return `T${sig}thread:1f03;00:${le64(0)};01:${le64(0)};10:${le64(0)};20:${le64(pc)};`;
}

const BRK_F00D = 0xD4200000 | (0xf00d << 5);
const NOT_BRK_F00D = 0x01000000 | (0xf00d << 5);   // bits 20:5 look like brk 0xf00d, the opcode is not brk
const instructions = { 0x100001000: NOT_BRK_F00D, 0x100002000: BRK_F00D };
const stops = [stop('0b', 0x100001000), stop('05', 0x100002000)];

const sent = [];
function send_command(c) {
    sent.push(c);
    if (c.startsWith('vAttach')) return 'T05thread:1f03;';   // the script requires a stop packet from vAttach; 'OK' is an attach failure
    if (c === 'c' || c.startsWith('vCont;')) return stops.shift();
    if (c.startsWith('m')) return le32(instructions[parseInt(c.slice(1), 16)]);
    return 'OK';
}
function get_pid() { return 1234; }
function log() {}
function prepare_memory_region() { return 'OK'; }

load('ios/Henge/Resources/henge-jit.js');

function check(cond, what) {
    if (!cond) { print(`FAIL: ${what}\n  sent: ${JSON.stringify(sent)}`); quit(1); }
}
check(sent.includes('vCont;S0b:1f03'), 'a stop that is not a brk resumes with its signal');
check(sent.indexOf('vCont;S0b:1f03') < sent.findIndex(c => c.startsWith('P20=')), 'the signal goes back before any other write');
check(sent.filter(c => c.startsWith('P20=')).length === 1, 'only the brk moves the pc');
check(sent.includes(`P20=${le64(0x100002004)};thread:1f03;`), 'the brk path writes pc + 4');
check(sent.includes('D'), 'the brk command still runs (detach)');
check(sent.filter(c => c === 'c').length === 1, 'the stop after the signal is used without another continue');
print('test_jit_script: ok');
