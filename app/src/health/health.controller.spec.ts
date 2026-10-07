import { ServiceUnavailableException } from '@nestjs/common';
import { Test, TestingModule } from '@nestjs/testing';
import { PG_POOL } from '../database/database.module.js';
import { HealthController } from './health.controller.js';

describe('HealthController', () => {
  let controller: HealthController;
  const pool = { query: vi.fn() };

  beforeEach(async () => {
    pool.query.mockReset();
    const module: TestingModule = await Test.createTestingModule({
      controllers: [HealthController],
      providers: [{ provide: PG_POOL, useValue: pool }],
    }).compile();

    controller = module.get(HealthController);
  });

  it('reports ok without touching the database', () => {
    expect(controller.check()).toEqual({ status: 'ok' });
    expect(pool.query).not.toHaveBeenCalled();
  });

  it('is ready when the database answers', async () => {
    pool.query.mockResolvedValue({ rows: [{ '?column?': 1 }] });

    await expect(controller.ready()).resolves.toEqual({ status: 'ok' });
    expect(pool.query).toHaveBeenCalledWith('SELECT 1');
  });

  it('is not ready when the database is unreachable', async () => {
    pool.query.mockRejectedValue(new Error('connect ECONNREFUSED'));

    await expect(controller.ready()).rejects.toBeInstanceOf(
      ServiceUnavailableException,
    );
  });
});
