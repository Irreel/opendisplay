import { mkdir, appendFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';

export interface Logger {
  event(type: string, fields?: Record<string, unknown>): Promise<void>;
}

export function defaultLogPath(): string {
  return (
    process.env['DESIGN_CANVAS_LOG_PATH'] ??
    join(homedir(), 'Library', 'Logs', 'DesignCanvas', 'server.log')
  );
}

export function createLogger(logPath = defaultLogPath()): Logger {
  return {
    async event(type, fields = {}) {
      await mkdir(dirname(logPath), { recursive: true });
      const line = JSON.stringify({
        ts: new Date().toISOString(),
        type,
        ...fields,
      });
      await appendFile(logPath, `${line}\n`, 'utf8');
    },
  };
}
