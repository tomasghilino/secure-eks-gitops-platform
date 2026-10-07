import { PostgreSqlContainer } from '@testcontainers/postgresql';
import { runner } from 'node-pg-migrate';
import type { TestProject } from 'vitest/node';

declare module 'vitest' {
  export interface ProvidedContext {
    database: {
      host: string;
      port: number;
      database: string;
      user: string;
      password: string;
    };
  }
}

export default async function setup(project: TestProject) {
  const container = await new PostgreSqlContainer('postgres:17-alpine').start();

  await runner({
    databaseUrl: container.getConnectionUri(),
    dir: 'migrations',
    direction: 'up',
    migrationsTable: 'pgmigrations',
    log: () => undefined,
  });

  project.provide('database', {
    host: container.getHost(),
    port: container.getPort(),
    database: container.getDatabase(),
    user: container.getUsername(),
    password: container.getPassword(),
  });

  return async () => {
    await container.stop();
  };
}
