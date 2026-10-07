import {
  ConflictException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { type User, UsersRepository } from './users.repository.js';
import type { CreateUserInput } from './users.schemas.js';

@Injectable()
export class UsersService {
  constructor(private readonly users: UsersRepository) {}

  findAll(): Promise<User[]> {
    return this.users.findAll();
  }

  async findById(id: string): Promise<User> {
    const user = await this.users.findById(id);
    if (!user) {
      throw new NotFoundException('user not found');
    }
    return user;
  }

  async create(input: CreateUserInput): Promise<User> {
    const user = await this.users.create(input);
    if (!user) {
      throw new ConflictException('email already registered');
    }
    return user;
  }

  async remove(id: string): Promise<void> {
    const deleted = await this.users.delete(id);
    if (!deleted) {
      throw new NotFoundException('user not found');
    }
  }
}
