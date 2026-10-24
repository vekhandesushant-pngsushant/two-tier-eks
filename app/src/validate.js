// Pure function - easy to unit test (no DB needed)
function validateTitle(title) {
  if (typeof title !== 'string') return { ok: false, error: 'title must be a string' };
  const t = title.trim();
  if (t.length === 0) return { ok: false, error: 'title is required' };
  if (t.length > 255) return { ok: false, error: 'title too long (max 255)' };
  return { ok: true, value: t };
}
module.exports = { validateTitle };
