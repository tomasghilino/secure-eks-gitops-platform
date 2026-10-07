import { INestApplication, Logger } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import request from 'supertest';
import type { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import { PG_POOL } from './../src/database/database.module.js';
import { poolThatMustNotBeUsed } from './unused-pool.js';

describe('Request logging (e2e)', () => {
  let app: INestApplication<App>;
  const log = vi.spyOn(Logger.prototype, 'log');
  const warn = vi.spyOn(Logger.prototype, 'warn');

  beforeAll(async () => {
    const moduleFixture = await Test.createTestingModule({
      imports: [AppModule],
    })
      .overrideProvider(PG_POOL)
      .useValue(poolThatMustNotBeUsed)
      .compile();

    app = moduleFixture.createNestApplication();
    await app.init();
  });

  beforeEach(() => {
    vi.clearAllMocks();
  });

  afterAll(async () => {
    await app.close();
    vi.restoreAllMocks();
  });

  it('logs requests to routes that do not exist', async () => {
    await request(app.getHttpServer()).get('/.env').expect(404);

    expect(warn).toHaveBeenCalledWith(
      expect.objectContaining({ method: 'GET', path: '/.env', status: 404 }),
    );
  });

  it('does not log load balancer health checks', async () => {
    await request(app.getHttpServer()).get('/health').expect(200);

    expect(log).not.toHaveBeenCalledWith(
      expect.objectContaining({ path: '/health' }),
    );
  });
});
