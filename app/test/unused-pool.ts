export const poolThatMustNotBeUsed = {
  query: () => {
    throw new Error('this test must not depend on the database');
  },
  end: () => Promise.resolve(),
};
