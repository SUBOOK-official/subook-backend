import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

const id = (n) => `00000000-0000-0000-0000-${String(n).padStart(12, '0')}`;

test('주문 구매 차수: 전체 이력, 비회원 정규화, 미결제/환불, 동시각 및 접근 권한', async (t) => {
  const db = new PGlite();
  try {
    await db.exec(`
      create role anon; create role authenticated;
      create function public.is_admin_user() returns boolean language sql stable as $$
        select nullif(current_setting('test.admin', true), '')::boolean
      $$;
      create table public.orders (
        id uuid primary key, user_id uuid, shipping_recipient_phone text,
        payment_status text, paid_at timestamptz, pg_approved_at timestamptz, created_at timestamptz
      );
      alter table public.orders enable row level security;
    `);
    await db.exec(readFileSync(new URL('../supabase/migrations/20260928055823_admin_order_purchase_rounds.sql', import.meta.url), 'utf8'));
    const add = async (n, user, payment, time, phone = '010-1111-2222', legacy = false) => db.query(
      'insert into public.orders values ($1, $2, $3, $4, $5, $6, $7)',
      [id(n), user ? id(user) : null, phone, payment,
        payment === 'pending' || payment === 'cancelled' || legacy ? null : time,
        legacy ? time : null, time],
    );
    await add(1, 100, 'paid', '2026-01-01T00:00:00Z');
    await add(2, 100, 'pending', '2026-01-02T00:00:00Z');
    await add(3, 100, 'cancelled', '2026-01-03T00:00:00Z');
    await add(4, 100, 'refunded', '2026-02-01T00:00:00Z');
    await add(5, 100, 'paid', '2026-03-01T00:00:00Z', '01099998888', true);
    await add(6, 200, 'paid', '2026-03-01T00:00:00Z');
    await add(7, null, 'paid', '2026-01-01T00:00:00Z');
    await add(8, null, 'paid', '2026-02-01T00:00:00Z', '01011112222');
    await add(9, null, 'paid', '2026-02-02T00:00:00Z', '');
    await add(10, null, 'paid', '2026-02-03T00:00:00Z', null);
    await add(11, 100, 'paid', '2026-03-01T00:00:00Z');
    await add(12, 100, 'pending', '2026-04-01T00:00:00Z');
    await add(13, 100, 'paid', '2026-05-01T00:00:00Z');
    const rounds = async (numbers) => (await db.query(
      'select public.admin_order_purchase_rounds($1::uuid[]) as rounds',
      [numbers === null ? null : numbers.map(id)],
    )).rows[0].rounds;

    await t.test('익명과 일반 회원은 구매 이력을 조회할 수 없다', async () => {
      await db.exec('set role anon');
      await assert.rejects(rounds([1]), /permission denied/);
      await db.exec('reset role; set role authenticated');
      await assert.rejects(rounds([1]), /관리자만/);
      await db.exec("select set_config('test.admin', 'false', false)");
      await assert.rejects(rounds([1]), /관리자만/);
      await db.exec("select set_config('test.admin', 'true', false)");
    });
    await t.test('페이지 밖 과거 결제와 환불 포함, 미결제/취소와 미래 결제 제외', async () => {
      assert.deepEqual(await rounds([5]), { [id(5)]: 3 });
      assert.deepEqual(await rounds([1, 4, 6]), { [id(1)]: 1, [id(4)]: 2, [id(6)]: 1 });
    });
    await t.test('비회원 번호의 하이픈 정규화, 회원과 분리, 빈 번호끼리 합치지 않음', async () => {
      assert.deepEqual(await rounds([7, 8, 9, 10]), { [id(7)]: 1, [id(8)]: 2, [id(9)]: 1, [id(10)]: 1 });
    });
    await t.test('동일 결제 시각은 주문 ID 순서로 결정', async () => {
      assert.deepEqual(await rounds([11, 5]), { [id(11)]: 4, [id(5)]: 3 });
    });
    await t.test('입금대기는 생성 당시 이전 결제에 현재 주문만 더함', async () => {
      assert.deepEqual(await rounds([2, 12, 13]), { [id(2)]: 2, [id(12)]: 5, [id(13)]: 5 });
    });
    await t.test('빈 입력/없는 주문, 중복 ID, 최대 요청 개수 처리', async () => {
      assert.deepEqual(await rounds([]), {});
      assert.deepEqual(await rounds(null), {});
      assert.deepEqual(await rounds([999]), {});
      assert.deepEqual(await rounds([5, 5]), { [id(5)]: 3 });
      await assert.rejects(rounds(Array(101).fill(1)), /최대 100개/);
    });
  } finally {
    await db.close();
  }
});
