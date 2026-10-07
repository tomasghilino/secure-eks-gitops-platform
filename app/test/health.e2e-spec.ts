import { Test, TestingModule } from '@nestjs/testing';
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { App } from 'supertest/types.js';
import { AppModule } from './../src/app.module.js';
import { PG_POOL } from './../src/database/database.module.js';
import { poolThatMustNotBeUsed } from './unused-pool.js';

describe('Health (e2e)', () => {
  let app: INestApplication<App>;

  beforeEach(async () => {
    const moduleFixture: TestingModule = await Test.createTestingModule({
      imports: [AppModule],
    })
      .overrideProvider(PG_POOL)
      .useValue(poolThatMustNotBeUsed)
      .compile();

    app = moduleFixture.createNestApplication();
    await app.init();
  });

  it('GET /health returns 200 without using the database', () => {
    return request(app.getHttpServer())
      .get('/health')
      .expect(200)
      .expect('Content-Type', /application\/json/)
      .expect({ status: 'ok' });
  });

  afterEach(async () => {
    await app.close();
  });
});
