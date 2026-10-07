import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    globals: true,
    root: './',
    include: ['**/*.spec.ts'],
    coverage: {
      provider: 'v8',
      include: ['src/**/*.ts'],
      exclude: ['src/**/*.spec.ts'],
      reportsDirectory: 'coverage/unit',
      reporter: ['text-summary', ['lcovonly', { projectRoot: '..' }]],
    },
  },
});
