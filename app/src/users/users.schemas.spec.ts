import {
  createUserSchema,
  listUsersQuerySchema,
  userIdSchema,
} from './users.schemas.js';

describe('createUserSchema', () => {
  it('accepts a valid user and trims the name', () => {
    expect(
      createUserSchema.parse({ name: '  Ada  ', email: 'ada@example.com' }),
    ).toEqual({ name: 'Ada', email: 'ada@example.com' });
  });

  it('rejects fields that are not part of the contract', () => {
    const result = createUserSchema.safeParse({
      name: 'Ada',
      email: 'ada@example.com',
      id: '3f0c8a2e-6d4b-4f1a-9c7e-2b5d8e1a4f60',
    });
    expect(result.success).toBe(false);
  });

  it('rejects an invalid email', () => {
    const result = createUserSchema.safeParse({ name: 'Ada', email: 'ada' });
    expect(result.success).toBe(false);
  });

  it('rejects a blank name', () => {
    const result = createUserSchema.safeParse({
      name: '   ',
      email: 'ada@example.com',
    });
    expect(result.success).toBe(false);
  });

  it('rejects a name longer than 100 characters', () => {
    const result = createUserSchema.safeParse({
      name: 'a'.repeat(101),
      email: 'ada@example.com',
    });
    expect(result.success).toBe(false);
  });
});

describe('userIdSchema', () => {
  it('accepts a uuid', () => {
    expect(
      userIdSchema.safeParse('3f0c8a2e-6d4b-4f1a-9c7e-2b5d8e1a4f60').success,
    ).toBe(true);
  });

  it('rejects a non uuid value', () => {
    expect(userIdSchema.safeParse('1').success).toBe(false);
  });
});

describe('listUsersQuerySchema', () => {
  it('defaults to the first 50 users', () => {
    expect(listUsersQuerySchema.parse({})).toEqual({ limit: 50, offset: 0 });
  });

  it('reads limit and offset from query strings', () => {
    expect(listUsersQuerySchema.parse({ limit: '10', offset: '20' })).toEqual({
      limit: 10,
      offset: 20,
    });
  });

  it.each(['0', '101', '1.5', 'abc'])('rejects limit %s', (limit) => {
    expect(listUsersQuerySchema.safeParse({ limit }).success).toBe(false);
  });

  it('rejects a negative offset', () => {
    expect(listUsersQuerySchema.safeParse({ offset: '-1' }).success).toBe(
      false,
    );
  });
});
