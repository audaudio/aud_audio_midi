// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Builds and runs the native tests of the MIDI bridge (ticket 26): the byte
// parser, the tap adapter and the port nodes, the latter through the graph
// engine of aud_audio_graph with its debug watchdog. Up to three builds,
// like the graph's and the sampler's tests:
//
// - the address and the undefined behaviour sanitizer,
// - Clang's RealtimeSanitizer when a compiler on this machine has it, for
//   the process calls of the nodes and the tap path, with a probe that
//   proves the run catches an allocation on the audio thread,
// - the thread sanitizer for the producer thread, GONE from another thread
//   and the close of an adapter under traffic.
//
// Every translation unit compiles to an object cached under .dart_tool by
// the hash of its flags, its source and the headers, in parallel; a run
// without changes only links and executes. Each build keeps only the
// objects and the binary of its last run. The options are in `usage` below.

'use strict';

const { createHash } = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { fileURLToPath, pathToFileURL } = require('node:url');

// On Windows, clang++ and the runtime of its sanitizers come from the LLVM
// of Visual Studio (component "C++ Clang compiler for Windows"), and the
// test binaries need the .exe suffix to start (ticket 38).
const exe = process.platform === 'win32' ? '.exe' : '';
if (process.platform === 'win32') useVisualStudioLlvm();

function useVisualStudioLlvm() {
  const vswhere = path.join(
    process.env['ProgramFiles(x86)'] || 'C:/Program Files (x86)',
    'Microsoft Visual Studio',
    'Installer',
    'vswhere.exe',
  );
  const found = spawnSync(
    vswhere,
    ['-latest', '-products', '*', '-find', 'VC/Tools/Llvm/x64/bin/clang++.exe'],
    { encoding: 'utf8' },
  );
  const clang = found.status === 0 ? found.stdout.split(/\r?\n/)[0].trim() : '';
  if (!clang) return;
  const resourceDir = spawnSync(clang, ['-print-resource-dir'], {
    encoding: 'utf8',
  }).stdout.trim();
  process.env.PATH = [
    path.dirname(clang),
    path.join(resourceDir, 'lib', 'windows'),
    process.env.PATH,
  ].join(path.delimiter);
  // lld-link refuses the allocators that the watchdog and the test
  // allocators replace next to those of the ASan runtime; MSVC's link.exe
  // takes ours. Every clang call gets it, without an unused-argument warning
  // when it only compiles.
  process.env.CCC_OVERRIDE_OPTIONS =
    '# +-fuse-ld=link +-Wno-unused-command-line-argument';
}

const root = path.resolve(__dirname, '..');

// The builds --only= names.
const variants = ['asan', 'plain', 'rtsan', 'tsan'];

const usage = `Usage: node scripts/test-native.js [options]

  (no options)      every build this machine has
  --no-sanitize     one build, no sanitizer
  --rtsan           fail without rtsan
  --no-rtsan        skip the rtsan build
  --no-tsan         skip the thread sanitizer
  --only=<build>    one build: ${variants.join(', ')}
  --help            this text

  AUD_TEST_FILTER=<part of a name>     run the matching tests only
  AUD_GRAPH_SRC=<directory>            the src of aud_audio_graph to build the
                                       nodes against, instead of the package
                                       config's
`;

// The options of the command line; anything else ends the run with the
// usage and exit code 2.
function parseArgs(argv) {
  const options = {
    sanitize: true,
    wantRtsan: false,
    noRtsan: false,
    noTsan: false,
    only: '',
  };
  for (const arg of argv) {
    if (arg === '--help') {
      process.stdout.write(usage);
      process.exit(0);
    } else if (arg === '--no-sanitize') {
      options.sanitize = false;
    } else if (arg === '--rtsan') {
      options.wantRtsan = true;
    } else if (arg === '--no-rtsan') {
      options.noRtsan = true;
    } else if (arg === '--no-tsan') {
      options.noTsan = true;
    } else if (arg.startsWith('--only=') && variants.includes(arg.slice(7))) {
      options.only = arg.slice(7);
    } else {
      process.stderr.write(`Unknown option ${arg}\n\n${usage}`);
      process.exit(2);
    }
  }
  return options;
}

const options = parseArgs(process.argv.slice(2));
const { sanitize, wantRtsan, only } = options;
const skipRtsan =
  options.noRtsan || !sanitize || (only !== '' && only !== 'rtsan');
const skipTsan =
  options.noTsan || !sanitize || (only !== '' && only !== 'tsan');
const skipMain = only !== '' && only !== 'asan' && only !== 'plain';

// Compilers that may carry the RealtimeSanitizer: Apple's clang refuses
// it on arm64, LLVM from Homebrew has it.
const rtsanCandidates = [
  process.env.AUD_RTSAN_CXX,
  '/opt/homebrew/opt/llvm/bin/clang++',
  '/usr/local/opt/llvm/bin/clang++',
  'clang++',
].filter(Boolean);

// The root directory of a package, resolved through the package config.
function packageRoot(name) {
  const configPath = path.join(root, '.dart_tool', 'package_config.json');
  if (!fs.existsSync(configPath)) {
    throw new Error(`Run dart pub get first: ${configPath} is missing`);
  }
  const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  const entry = config.packages.find((p) => p.name === name);
  if (!entry) throw new Error(`Package ${name} is not in the package config`);
  const rootUri = new URL(entry.rootUri, pathToFileURL(configPath));
  return fileURLToPath(rootUri);
}

function listFiles(directory, extensions) {
  return fs
    .readdirSync(directory)
    .filter((file) => extensions.some((extension) => file.endsWith(extension)))
    .map((file) => path.join(directory, file))
    .sort();
}

// Every header below the include directories, recursively.
function headersBelow(directories) {
  const result = [];
  const visit = (directory) => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const file = path.join(directory, entry.name);
      if (entry.isDirectory()) {
        visit(file);
      } else if (/\.(h|hh|hpp|hxx|inc|ipp)$/.test(entry.name)) {
        result.push(file);
      }
    }
  };
  for (const directory of directories) visit(directory);
  return [...new Set(result)].sort();
}

// Whether `compiler` exists and builds a program with `flags`.
function works(compiler, flags) {
  const probe = spawnSync(compiler, ['--version'], { encoding: 'utf8' });
  if (probe.status !== 0) return false;
  if (flags.length === 0) return true;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'aud-probe-'));
  try {
    const source = path.join(dir, 'probe.cpp');
    fs.writeFileSync(source, 'int main() { return 0; }\n');
    const build = spawnSync(
      compiler,
      [...flags, source, '-o', path.join(dir, `probe${exe}`)],
      { encoding: 'utf8' },
    );
    return build.status === 0;
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

function rtsanCompiler() {
  for (const candidate of rtsanCandidates) {
    if (works(candidate, ['-fsanitize=realtime'])) return candidate;
  }
  return null;
}

// The units to compile with their own flags: the graph engine with the
// watchdog, the bridge as the build hook compiles it, the tests.
function units(context) {
  const graphFlags = ['-DAUD_GRAPH_WATCHDOG=1'];
  if (context.rtsan) graphFlags.push('-DAUD_GRAPH_RTSAN=1');
  const result = [];
  for (const file of context.graphSources) {
    result.push({ file, flags: graphFlags });
  }
  const own = ['-Wall', '-Wextra', '-Wno-unused-parameter'];
  for (const file of context.bridgeSources) result.push({ file, flags: own });
  for (const file of context.testSources) result.push({ file, flags: own });
  return result;
}

function runCompiler(compiler, flags) {
  return new Promise((resolve) => {
    const child = spawn(compiler, flags, { stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    child.stdout.on('data', (data) => (output += data));
    child.stderr.on('data', (data) => (output += data));
    child.on('close', (status) => resolve({ status, output }));
  });
}

// The folder of the objects and the binary of a build.
function outDirOf(name) {
  return path.join(root, '.dart_tool', 'aud_native_test', name);
}

// Compiles what is not cached, at most one unit per core at a time; returns
// the objects.
async function compileAll(name, compiler, variantFlags, context) {
  const outDir = outDirOf(name);
  fs.mkdirSync(outDir, { recursive: true });
  const common = [
    '-c',
    '-std=c++17',
    '-g',
    '-O1',
    '-fno-omit-frame-pointer',
    ...variantFlags,
    ...context.includes.map((directory) => `-I${directory}`),
  ];
  const jobs = units(context).map(({ file, flags }) => {
    const all = [...common, ...flags];
    const hash = createHash('sha256');
    hash.update(compiler);
    hash.update(all.join(' '));
    hash.update(context.headersHash);
    hash.update(fs.readFileSync(file));
    const object = path.join(
      outDir,
      `${path.basename(file)}-${hash.digest('hex').slice(0, 16)}.o`,
    );
    return { file, object, flags: [...all, file, '-o', object] };
  });
  const pending = jobs.filter((job) => !fs.existsSync(job.object));
  if (pending.length > 0) {
    process.stdout.write(`${name}: compiling ${pending.length} units\n`);
  }
  let next = 0;
  let failed = null;
  const worker = async () => {
    while (next < pending.length && failed === null) {
      const job = pending[next++];
      const result = await runCompiler(compiler, job.flags);
      if (result.status !== 0) {
        failed = `${job.file}\n${result.output}`;
      } else if (result.output.trim().length > 0) {
        process.stdout.write(result.output);
      }
    }
  };
  const parallel = Math.max(1, os.cpus().length);
  await Promise.all(Array.from({ length: parallel }, worker));
  if (failed !== null) {
    process.stderr.write(`${name}: compiling failed: ${failed}\n`);
    process.exit(1);
  }
  return jobs.map((job) => job.object);
}

async function build(name, compiler, variantFlags, context) {
  const objects = await compileAll(name, compiler, variantFlags, context);
  const hash = createHash('sha256');
  for (const object of objects) hash.update(object);
  const outDir = outDirOf(name);
  const binary = path.join(
    outDir,
    `aud_midi_test-${hash.digest('hex').slice(0, 16)}${exe}`,
  );
  if (!fs.existsSync(binary)) {
    const flags = [...variantFlags, ...objects, '-o', binary];
    if (process.platform !== 'win32') flags.push('-lpthread');
    const result = spawnSync(compiler, flags, { encoding: 'utf8' });
    if (result.status !== 0) {
      process.stderr.write(result.stdout + result.stderr);
      process.exit(result.status ?? 1);
    }
  }
  prune(outDir, [...objects, binary]);
  return binary;
}

// Removes what earlier runs left in the folder of a build: the objects and
// binaries of sources, headers or flags that changed since.
function prune(outDir, keep) {
  const kept = new Set(keep.map((file) => path.basename(file)));
  for (const entry of fs.readdirSync(outDir)) {
    if (kept.has(entry)) continue;
    fs.rmSync(path.join(outDir, entry), { recursive: true, force: true });
  }
}

function execute(binary, env) {
  return spawnSync(binary, [], {
    encoding: 'utf8',
    cwd: root,
    env: { ...process.env, ...env },
    maxBuffer: 64 * 1024 * 1024,
  });
}

function run(name, binary, env) {
  process.stdout.write(`${name}: ${path.basename(binary)}\n`);
  const result = execute(binary, env);
  process.stdout.write(result.stdout);
  process.stderr.write(result.stderr);
  if (result.status !== 0) process.exit(result.status ?? 1);
}

// The rtsan run must catch an allocation on the audio thread (the probe
// node) and one inside the tap (the probe push) once the probes stop
// telling the sanitizer; otherwise its silence would prove nothing. The
// filters match one probe each.
function probeRtsan(binary, env) {
  for (const probe of ['rtsan_probe', 'rtsan_tap_probe']) {
    const result = execute(binary, {
      ...env,
      AUD_TEST_FILTER: probe,
      AUD_TEST_RTSAN_PROBE: '1',
    });
    if (result.status === 0 || !result.stderr.includes('RealtimeSanitizer')) {
      process.stderr.write(
        `rtsan: the allocation of ${probe} was not caught\n` +
          result.stdout +
          result.stderr,
      );
      process.exit(1);
    }
    process.stdout.write(`rtsan: the allocation of ${probe} was caught\n`);
  }
}

async function main() {
  const coreSrc = path.join(packageRoot('aud_audio_core'), 'src');
  const graphSrc =
    process.env.AUD_GRAPH_SRC || path.join(packageRoot('aud_audio_graph'), 'src');
  const includes = [
    path.join(root, 'src'),
    coreSrc,
    graphSrc,
    path.join(root, 'test', 'native'),
  ];
  const headers = headersBelow(includes);
  const headersHash = createHash('sha256');
  for (const header of headers) {
    headersHash.update(header);
    headersHash.update(fs.readFileSync(header));
  }
  const context = {
    includes,
    headersHash: headersHash.digest('hex'),
    graphSources: listFiles(graphSrc, ['.cpp']),
    bridgeSources: listFiles(path.join(root, 'src'), ['.cpp']),
    testSources: listFiles(path.join(root, 'test', 'native'), ['.cpp']),
    rtsan: false,
  };

  const compiler = 'clang++';
  if (!works(compiler, [])) throw new Error('clang++ is missing');
  // The leak check exists on Linux only; Apple's runtime refuses the option.
  const leaks =
    process.platform === 'linux' ? 'detect_leaks=1' : 'detect_leaks=0';
  const plain = !sanitize || only === 'plain';
  if (!skipMain) {
    const main = await build(
      plain ? 'plain' : 'asan',
      compiler,
      plain ? [] : ['-fsanitize=address,undefined'],
      context,
    );
    run(plain ? 'plain' : 'asan+ubsan', main, {
      UBSAN_OPTIONS: 'print_stacktrace=1:halt_on_error=1',
      ASAN_OPTIONS: leaks,
    });
  }
  if (!skipRtsan) {
    const rtsanCxx = rtsanCompiler();
    if (rtsanCxx === null) {
      if (wantRtsan) {
        throw new Error('No compiler with -fsanitize=realtime found');
      }
      process.stdout.write('rtsan: no compiler has it, skipped\n');
    } else {
      const rtsan = await build(
        'rtsan',
        rtsanCxx,
        ['-fsanitize=realtime', '-Wno-function-effects'],
        { ...context, rtsan: true },
      );
      // Every violation aborts the run: the tests fail on any.
      const env = { RTSAN_OPTIONS: 'halt_on_error=true' };
      run('rtsan', rtsan, env);
      probeRtsan(rtsan, env);
    }
  }
  if (!skipTsan) {
    if (!works(compiler, ['-fsanitize=thread'])) {
      process.stdout.write('tsan: the compiler lacks it, skipped\n');
      return;
    }
    const tsan = await build('tsan', compiler, ['-fsanitize=thread'], context);
    run('tsan', tsan, {
      TSAN_OPTIONS: 'halt_on_error=1:second_deadlock_stack=1',
    });
  }
}

main().catch((error) => {
  process.stderr.write(`${error.stack ?? error}\n`);
  process.exit(1);
});
