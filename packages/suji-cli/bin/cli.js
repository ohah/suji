#!/usr/bin/env node
import { runInitCli } from "../lib/init.js";

await runInitCli(process.argv.slice(2));
