import { defineConfig } from 'vitest/config';
import path from 'path';

export default defineConfig({
  // Match Next.js' automatic JSX runtime when exercising actual client components.
  esbuild: { jsx: 'automatic' },
  test: {
    include: ['src/**/*.test.ts'],
    environment: 'node',
  },
  resolve: {
    alias: { '@': path.resolve(__dirname, './src') },
  },
});
