import { Test, TestingModule } from '@nestjs/testing';
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import { PG_POOL } from './../src/database/database.module.js';
import { applySecurityHeaders } from './../src/security-headers.js';
import { poolThatMustNotBeUsed } from './unused-pool.js';

describe('Security headers (e2e)', () => {
  let app: INestApplication<App>;

  beforeEach(async () => {
    const moduleFixture: TestingModule = await Test.createTestingModule({
      imports: [AppModule],
    })
      .overrideProvider(PG_POOL)
      .useValue(poolThatMustNotBeUsed)
      .compile();

    app = moduleFixture.createNestApplication();
    applySecurityHeaders(app);
    await app.init();
  });

  it.each(['/health', '/does-not-exist'])(
    'GET %s hides the framework and blocks mime sniffing',
    async (path) => {
      const response = await request(app.getHttpServer()).get(path);

      expect(response.headers['x-powered-by']).toBeUndefined();
      expect(response.headers['x-content-type-options']).toBe('nosniff');
    },
  );

  afterEach(async () => {
    await app.close();
  });
});
