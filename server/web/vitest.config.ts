import { defineConfig } from 'vitest/config';

// Tests are about plain functions (src/lib): no plugins, no browser.
export default defineConfig({ test: { environment: 'node', include: ['src/**/*.test.ts'] } });
