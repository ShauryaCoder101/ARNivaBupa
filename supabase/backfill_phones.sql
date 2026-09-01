-- =====================================================================
-- backfill_phones.sql — give existing merchandisers a phone login.
-- NOT a migration. Run by hand, once, after 0007_phone_identity.sql.
--
-- Why this is not automated: a phone number IS the login identity after
-- 0007. Inventing one does not create a harmless placeholder — it creates
-- an account a real person cannot sign into, and risks colliding with a
-- number that belongs to somebody else. The numbers have to come from
-- whoever actually employs these merchandisers.
-- =====================================================================

-- ---------------------------------------------------------------------
-- STEP 1 — who is there, and who still cannot sign in?
-- ---------------------------------------------------------------------
select p.full_name,
       p.role,
       p.is_active,
       coalesce(p.phone, '(none — cannot sign in)') as phone,
       u.email                                      as current_login
  from public.profiles p
  join auth.users u on u.id = p.id
 where p.role = 'Merchandiser'
 order by p.is_active desc, p.full_name;

-- ---------------------------------------------------------------------
-- STEP 2 — fill in the real numbers and run.
--
-- DIGITS ONLY. No +, no spaces, no leading zero: profiles_phone_digits
-- rejects all three, deliberately, because a stray character would split
-- one person into two accounts. 10-digit Indian mobile => prefix 91.
--   98765 43210  ->  '919876543210'
-- ---------------------------------------------------------------------
-- update public.profiles set phone = '91XXXXXXXXXX' where full_name = 'Aditya Kulkarni';
-- update public.profiles set phone = '91XXXXXXXXXX' where full_name = 'Sneha Iyer';
-- update public.profiles set phone = '91XXXXXXXXXX' where full_name = 'Imran Sheikh';
-- update public.profiles set phone = '91XXXXXXXXXX' where full_name = 'Kavya Reddy';
-- update public.profiles set phone = '91XXXXXXXXXX' where full_name = 'Rahul Verma';
-- update public.profiles set phone = '91XXXXXXXXXX' where full_name = 'Meera Joshi';

-- ---------------------------------------------------------------------
-- STEP 3 — a backfilled row STILL CANNOT SIGN IN YET.
--
-- 0007 gives the profile a readable phone number. It does not touch
-- auth.users, where the login still carries the old @niva.example address
-- and whatever password it was created with. The app derives the address
-- from the phone (919876543210@phone.niva.internal), so the two no longer
-- agree and the sign-in fails.
--
-- Fix it one of two ways:
--   (a) Dashboard -> Authentication -> Users -> edit the user's email to
--       <digits>@phone.niva.internal and set a password; or
--   (b) ignore these rows and create the real people through the app's
--       Merchandisers tab, which does all of this in one call.
--
-- (b) is almost always right. These six are seed fixtures on a reserved
-- example domain, not staff.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- STEP 4 — retire the fixtures, once real accounts exist.
-- Deactivated rather than deleted: tasks reference profiles with RESTRICT
-- and the audit trail must keep naming a real row.
-- ---------------------------------------------------------------------
-- update public.profiles set is_active = false
--  where role = 'Merchandiser' and phone is null;
