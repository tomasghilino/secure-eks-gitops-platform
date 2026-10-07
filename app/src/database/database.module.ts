import { Inject, Logger, Module, OnApplicationShutdown } from '@nestjs/common';
import { Pool } from 'pg';

export const PG_POOL = Symbol('PG_POOL');

const REQUIRED_ENV = ['PGHOST', 'PGDATABASE', 'PGUSER', 'PGPASSWORD'];

function createPool(): Pool {
  const missing = REQUIRED_ENV.filter((name) => !process.env[name]);
  if (missing.length > 0) {
    throw new Error(
      `missing database environment variables: ${missing.join(', ')}`,
    );
  }

  const pool = new Pool({ connectionTimeoutMillis: 5000 });
  const logger = new Logger('Database');
  // without a listener, an idle client error such as a database restart crashes the process
  pool.on('error', (error) =>
    logger.error(`idle client error: ${error.message}`),
  );
  return pool;
}

@Module({
  providers: [{ provide: PG_POOL, useFactory: createPool }],
  exports: [PG_POOL],
})
export class DatabaseModule implements OnApplicationShutdown {
  constructor(@Inject(PG_POOL) private readonly pool: Pool) {}

  async onApplicationShutdown(): Promise<void> {
    await this.pool.end();
  }
}
