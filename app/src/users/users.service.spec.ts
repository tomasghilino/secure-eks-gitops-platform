import { ConflictException, NotFoundException } from '@nestjs/common';
import type { User, UsersRepository } from './users.repository.js';
import { UsersService } from './users.service.js';

const user: User = {
  id: '3f0c8a2e-6d4b-4f1a-9c7e-2b5d8e1a4f60',
  name: 'Ada',
  email: 'ada@example.com',
  createdAt: new Date('2026-01-01T00:00:00Z'),
};

describe('UsersService', () => {
  const repository = {
    findAll: vi.fn(),
    findById: vi.fn(),
    create: vi.fn(),
    delete: vi.fn(),
  };
  const service = new UsersService(repository as unknown as UsersRepository);

  beforeEach(() => {
    vi.resetAllMocks();
  });

  it('returns all users', async () => {
    repository.findAll.mockResolvedValue([user]);
    await expect(service.findAll()).resolves.toEqual([user]);
  });

  it('returns a user by id', async () => {
    repository.findById.mockResolvedValue(user);
    await expect(service.findById(user.id)).resolves.toEqual(user);
  });

  it('throws not found for an unknown id', async () => {
    repository.findById.mockResolvedValue(undefined);
    await expect(service.findById(user.id)).rejects.toThrow(NotFoundException);
  });

  it('creates a user', async () => {
    repository.create.mockResolvedValue(user);
    await expect(
      service.create({ name: user.name, email: user.email }),
    ).resolves.toEqual(user);
  });

  it('throws conflict when the email is already registered', async () => {
    repository.create.mockResolvedValue(undefined);
    await expect(
      service.create({ name: user.name, email: user.email }),
    ).rejects.toThrow(ConflictException);
  });

  it('deletes an existing user', async () => {
    repository.delete.mockResolvedValue(true);
    await expect(service.remove(user.id)).resolves.toBeUndefined();
  });

  it('throws not found when deleting an unknown id', async () => {
    repository.delete.mockResolvedValue(false);
    await expect(service.remove(user.id)).rejects.toThrow(NotFoundException);
  });
});
