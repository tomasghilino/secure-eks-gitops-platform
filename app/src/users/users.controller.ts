import {
  Body,
  Controller,
  Delete,
  Get,
  HttpCode,
  HttpStatus,
  Param,
  Post,
  Query,
} from '@nestjs/common';
import type { User } from './users.repository.js';
import {
  createUserSchema,
  listUsersQuerySchema,
  userIdSchema,
  type CreateUserInput,
  type ListUsersQuery,
} from './users.schemas.js';
import { UsersService } from './users.service.js';

@Controller('users')
export class UsersController {
  constructor(private readonly usersService: UsersService) {}

  @Get()
  list(
    @Query({ schema: listUsersQuerySchema }) query: ListUsersQuery,
  ): Promise<User[]> {
    return this.usersService.list(query);
  }

  @Get(':id')
  findById(@Param('id', { schema: userIdSchema }) id: string): Promise<User> {
    return this.usersService.findById(id);
  }

  @Post()
  create(
    @Body({ schema: createUserSchema }) input: CreateUserInput,
  ): Promise<User> {
    return this.usersService.create(input);
  }

  @Delete(':id')
  @HttpCode(HttpStatus.NO_CONTENT)
  remove(@Param('id', { schema: userIdSchema }) id: string): Promise<void> {
    return this.usersService.remove(id);
  }
}
