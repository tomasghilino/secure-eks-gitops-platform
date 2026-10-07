import { Inject, Injectable } from '@nestjs/common';
import { Pool } from 'pg';
import { PG_POOL } from '../database/database.module.js';
import type { CreateUserInput } from './users.schemas.js';

export interface User {
  id: string;
  name: string;
  email: string;
  createdAt: Date;
}

@Injectable()
export class UsersRepository {
  constructor(@Inject(PG_POOL) private readonly pool: Pool) {}

  async findAll(): Promise<User[]> {
    const { rows } = await this.pool.query<User>(
      'SELECT id, name, email, created_at AS "createdAt" FROM users ORDER BY created_at',
    );
    return rows;
  }

  async findById(id: string): Promise<User | undefined> {
    const { rows } = await this.pool.query<User>(
      'SELECT id, name, email, created_at AS "createdAt" FROM users WHERE id = $1',
      [id],
    );
    return rows[0];
  }

  async create(input: CreateUserInput): Promise<User | undefined> {
    const { rows } = await this.pool.query<User>(
      'INSERT INTO users (name, email) VALUES ($1, $2) ON CONFLICT DO NOTHING RETURNING id, name, email, created_at AS "createdAt"',
      [input.name, input.email],
    );
    return rows[0];
  }

  async delete(id: string): Promise<boolean> {
    const { rowCount } = await this.pool.query(
      'DELETE FROM users WHERE id = $1',
      [id],
    );
    return rowCount === 1;
  }
}
