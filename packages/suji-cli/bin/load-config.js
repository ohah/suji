#!/usr/bin/env node
import { configToJson, loadConfig } from "../lib/config-loader.js";

function parseArgs(argv) {
  const options = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const readValue = (flag) => {
      if (arg.startsWith(`${flag}=`)) return arg.slice(flag.length + 1);
      if (arg === flag) {
        i += 1;
        if (i >= argv.length) throw new Error(`${flag} requires a value`);
        return argv[i];
      }
      return null;
    };

    if (arg === "--help" || arg === "-h") {
      options.help = true;
      continue;
    }

    const cwd = readValue("--cwd");
    if (cwd !== null) {
      options.cwd = cwd;
      continue;
    }
    const config = readValue("--config");
    if (config !== null) {
      options.config = config;
      continue;
    }
    const command = readValue("--command");
    if (command !== null) {
      options.command = command;
      continue;
    }
    const mode = readValue("--mode");
    if (mode !== null) {
      options.mode = mode;
      continue;
    }

    throw new Error(`Unknown argument: ${arg}`);
  }
  return options;
}

try {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    process.stdout.write("Usage: suji-config [--cwd <dir>] [--config <file>] [--command <cmd>] [--mode <mode>]\n");
    process.exit(0);
  }
  const config = await loadConfig(options);
  process.stdout.write(configToJson(config));
} catch (error) {
  console.error(`error: ${error.message}`);
  if (process.env.SUJI_CONFIG_DEBUG && error.stack) console.error(error.stack);
  process.exit(1);
}
