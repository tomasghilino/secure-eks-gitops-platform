import { INestApplication } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import type { Pool } from 'pg';
import request from 'supertest';
import type { App } from 'supertest/types.js';
import { inject } from 'vitest';
import { AppModule } from './../src/app.module.js';
import { PG_POOL } from './../src/database/database.module.js';

describe('Users (e2e)', () => {
  let app: INestApplication<App>;
  let pool: Pool;

  const api = () => request(app.getHttpServer());

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
    pool = app.get(PG_POOL);
  });

  beforeEach(async () => {
    await pool.query('TRUNCATE users');
  });

  afterAll(async () => {
    await app.close();
  });

  it('creates a user and reads it back', async () => {
    const created = await api()
      .post('/users')
      .send({ name: '  Ada Lovelace ', email: 'ada@example.com' })
      .expect(201);

    expect(created.body).toEqual({
      id: expect.any(String),
      name: 'Ada Lovelace',
      email: 'ada@example.com',
      createdAt: expect.any(String),
    });

    await api().get(`/users/${created.body.id}`).expect(200, created.body);
  });

  it('lists users in creation order', async () => {
    await api()
      .post('/users')
      .send({ name: 'Ada', email: 'ada@example.com' })
      .expect(201);
    await api()
      .post('/users')
      .send({ name: 'Grace', email: 'grace@example.com' })
      .expect(201);

    const list = await api().get('/users').expect(200);

    expect(list.body.map((user: { name: string }) => user.name)).toEqual([
      'Ada',
      'Grace',
    ]);
  });

  it('rejects a duplicate email regardless of case', async () => {
    await api()
      .post('/users')
      .send({ name: 'Ada', email: 'ada@example.com' })
      .expect(201);

    await api()
      .post('/users')
      .send({ name: 'Ada Again', email: 'ADA@EXAMPLE.COM' })
      .expect(409);

    const list = await api().get('/users').expect(200);
    expect(list.body).toHaveLength(1);
  });

  it('rejects invalid input without writing anything', async () => {
    await api()
      .post('/users')
      .send({ name: 'Ada', email: 'not-an-email' })
      .expect(400);
    await api()
      .post('/users')
      .send({ name: 'Eve', email: 'eve@example.com', role: 'admin' })
      .expect(400);
    await api().post('/users').send({}).expect(400);

    await api().get('/users').expect(200, []);
  });

  it('returns 400 for a malformed id and 404 for an unknown id', async () => {
    await api().get('/users/not-a-uuid').expect(400);
    await api().get('/users/00000000-0000-4000-8000-000000000000').expect(404);
  });

  it('deletes a user exactly once', async () => {
    const created = await api()
      .post('/users')
      .send({ name: 'Ada', email: 'ada@example.com' })
      .expect(201);

    await api().delete(`/users/${created.body.id}`).expect(204);
    await api().get(`/users/${created.body.id}`).expect(404);
    await api().delete(`/users/${created.body.id}`).expect(404);
  });

  it('stores sql metacharacters as plain data', async () => {
    const name = "Robert'); DROP TABLE users;--";

    await api()
      .post('/users')
      .send({ name, email: 'bobby@example.com' })
      .expect(201);

    const list = await api().get('/users').expect(200);
    expect(list.body[0].name).toBe(name);
  });
});
