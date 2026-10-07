import { Test, TestingModule } from '@nestjs/testing';
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import type { App } from 'supertest/types.js';
import { inject } from 'vitest';
import { AppModule } from './../src/app.module.js';
import { PG_POOL } from './../src/database/database.module.js';

const unreachablePool = {
  query: () => Promise.reject(new Error('connect ECONNREFUSED')),
  end: () => Promise.resolve(),
};

describe('Health without a database (e2e)', () => {
  let app: INestApplication<App>;

  beforeEach(async () => {
    const moduleFixture: TestingModule = await Test.createTestingModule({
      imports: [AppModule],
    })
      .overrideProvider(PG_POOL)
      .useValue(unreachablePool)
      .compile();

    app = moduleFixture.createNestApplication();
    await app.init();
  });

  afterEach(async () => {
    await app.close();
  });

  it('GET /health stays 200, so the container is not restarted', () => {
    return request(app.getHttpServer())
      .get('/health')
      .expect(200)
      .expect('Content-Type', /application\/json/)
      .expect({ status: 'ok' });
  });

  it('GET /health/ready returns 503, so no traffic is sent', () => {
    return request(app.getHttpServer())
      .get('/health/ready')
      .expect(503)
      .expect((res) => {
        expect(res.body).toMatchObject({ message: 'database unreachable' });
      });
  });
});

describe('Health with a database (e2e)', () => {
  let app: INestApplication<App>;

  beforeAll(async () => {
    const database = inject('database');
    process.env.PGHOST = database.host;
    process.env.PGPORT = String(database.port);
    process.env.PGDATABASE = database.database;
    process.env.PGUSER = database.user;
    process.env.PGPASSWORD = database.password;

    const moduleFixture = await Test.createTestingModule({
      imports: [AppModule],
    }).compile();

    app = moduleFixture.createNestApplication();
    await app.init();
  });

  afterAll(async () => {
    await app.close();
  });

  it('GET /health/ready returns 200', () => {
    return request(app.getHttpServer())
      .get('/health/ready')
      .expect(200)
      .expect({ status: 'ok' });
  });
});
