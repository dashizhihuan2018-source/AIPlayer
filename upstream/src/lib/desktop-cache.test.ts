import { expect, it } from 'vitest';
import nextConfig from '../../next.config';

it('keeps runtime route and fetch cache writes out of the signed app bundle', () => {
  expect(nextConfig.experimental?.isrFlushToDisk).toBe(false);
});
