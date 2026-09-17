import { homedir } from 'node:os';
import { join } from 'node:path';

export interface StorePaths {
  root: string;
  captures: string;
  annotations: string;
}

export function defaultStoreRoot(): string {
  return (
    process.env['DESIGN_CANVAS_STORE_DIR'] ??
    join(homedir(), '.claude', 'channels', 'design-canvas')
  );
}

export function createStorePaths(root = defaultStoreRoot()): StorePaths {
  return {
    root,
    captures: join(root, 'captures'),
    annotations: join(root, 'annotations'),
  };
}
