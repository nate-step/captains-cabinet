import { defineConfig } from 'vitest/config'
import tsconfigPaths from 'vite-tsconfig-paths'

export default defineConfig({
  plugins: [tsconfigPaths()],
  test: {
    exclude: ['node_modules', '.next', '.next/**', 'dist'],
    globals: false,
    environment: 'node',
  },
})
