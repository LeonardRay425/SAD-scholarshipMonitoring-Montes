-- Scholarship Monitoring: run whole file in Supabase SQL Editor.
create extension if not exists pgcrypto;
create table programs(id serial primary key, name text unique not null, max_gwa numeric(3,2) not null,
 min_units int not null, max_failed int not null, max_inc int not null, max_drop int not null, deadline timestamptz not null);
insert into programs(name,max_gwa,min_units,max_failed,max_inc,max_drop,deadline) values
 ('Merit Scholar',1.75,18,0,0,0,'2026-10-30 17:00+08'),('Community Scholar',2.25,15,0,0,1,'2026-10-30 17:00+08');
create table profiles(id uuid primary key default gen_random_uuid(), auth_id uuid unique references auth.users on delete set null,
 email text unique, role text not null default 'scholar' check(role in('scholar','staff')), full_name text, student_id text unique);
create table assignments(scholar_id uuid primary key references profiles on delete cascade, program_id int not null references programs);
create table submissions(id uuid primary key default gen_random_uuid(), scholar_id uuid not null references profiles,
 academic_year text not null, semester int not null check(semester in(1,2,3)),
 gwa numeric(3,2) not null check(gwa between 1 and 5), units int not null check(units>=0), failed_count int not null check(failed_count>=0),
 incomplete_count int not null check(incomplete_count>=0), dropped_count int not null check(dropped_count>=0),
 evidence_ref text not null check(length(trim(evidence_ref))>0), submitted_at timestamptz not null default now(),
 verification_status text not null default 'Pending verification' check(verification_status in('Pending verification','Verified','Returned')),
 return_reason text, compliance text not null default 'Not evaluated' check(compliance in('Not evaluated','Compliant','With Deficiency')),
 deficiency_reasons text, checks jsonb, renewal_decision text not null default 'Pending' check(renewal_decision in('Pending','Approved','Held')),
 decision_note text, unique(scholar_id,academic_year,semester));
create table history(id bigserial primary key, submission_id uuid references submissions on delete cascade, actor_id uuid,
 action text not null, detail text, at timestamptz not null default now());

create function me() returns uuid language sql stable security definer set search_path=public as $$ select id from profiles where auth_id=auth.uid() $$;
create function is_staff() returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from profiles where auth_id=auth.uid() and role='staff') $$;

-- Row level security: clients may only READ (and staff manage profiles/assignments). All workflow writes go through RPCs below.
alter table programs enable row level security; alter table profiles enable row level security; alter table assignments enable row level security;
alter table submissions enable row level security; alter table history enable row level security;
create policy prog_read on programs for select to authenticated using(true);
create policy prof_read on profiles for select to authenticated using(auth_id=auth.uid() or is_staff());
create policy prof_staff on profiles for all to authenticated using(is_staff()) with check(is_staff());
create policy asg_read on assignments for select to authenticated using(scholar_id=me() or is_staff());
create policy asg_staff on assignments for all to authenticated using(is_staff()) with check(is_staff());
create policy sub_read on submissions for select to authenticated using(scholar_id=me() or is_staff());
create policy hist_read on history for select to authenticated using(is_staff() or exists(select 1 from submissions s where s.id=submission_id and s.scholar_id=me()));

create function log_h(sid uuid, act text, det text) returns void language sql security definer set search_path=public as
$$ insert into history(submission_id,actor_id,action,detail) values(sid,me(),act,det) $$;

create function _check_input(ay text,sem int,gwa numeric,u int,f int,i int,d int,ref text) returns void language plpgsql as $$
begin
 if ay !~ '^\d{4}-\d{4}$' then raise exception 'Academic year must look like 2026-2027.'; end if;
 if sem not in(1,2,3) then raise exception 'Semester must be 1, 2 or 3.'; end if;
 if gwa is null or gwa<1 or gwa>5 then raise exception 'GWA must be between 1.00 and 5.00 inclusive.'; end if;
 if u is null or f is null or i is null or d is null or u<0 or f<0 or i<0 or d<0 then raise exception 'Units and counts must be nonnegative whole numbers.'; end if;
 if ref is null or length(trim(ref))=0 then raise exception 'A grade-document reference is required.'; end if;
end $$;

create function submit_grades(p_ay text,p_sem int,p_gwa numeric,p_units int,p_failed int,p_inc int,p_drop int,p_ref text)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_me uuid:=me(); v_id uuid;
begin
 if v_me is null or not exists(select 1 from assignments where scholar_id=v_me) then raise exception 'You are not assigned to a scholarship program.'; end if;
 perform _check_input(p_ay,p_sem,p_gwa,p_units,p_failed,p_inc,p_drop,p_ref);
 insert into submissions(scholar_id,academic_year,semester,gwa,units,failed_count,incomplete_count,dropped_count,evidence_ref)
 values(v_me,p_ay,p_sem,p_gwa,p_units,p_failed,p_inc,p_drop,trim(p_ref)) returning id into v_id;
 perform log_h(v_id,'Submitted','Semester summary submitted'); return v_id;
exception when unique_violation then raise exception 'A submission for this academic year and semester already exists.';
end $$;

create function resubmit_grades(p_id uuid,p_gwa numeric,p_units int,p_failed int,p_inc int,p_drop int,p_ref text)
returns void language plpgsql security definer set search_path=public as $$
declare s submissions;
begin
 select * into s from submissions where id=p_id and scholar_id=me();
 if not found then raise exception 'Submission not found.'; end if;
 if s.verification_status<>'Returned' then raise exception 'Only returned submissions can be corrected.'; end if;
 perform _check_input(s.academic_year,s.semester,p_gwa,p_units,p_failed,p_inc,p_drop,p_ref);
 update submissions set gwa=p_gwa,units=p_units,failed_count=p_failed,incomplete_count=p_inc,dropped_count=p_drop,evidence_ref=trim(p_ref),
  verification_status='Pending verification',return_reason=null,compliance='Not evaluated',deficiency_reasons=null,checks=null,
  renewal_decision='Pending',decision_note=null where id=p_id;
 perform log_h(p_id,'Resubmitted','Correction submitted; back to Pending verification');
end $$;

create function verify_submission(p_id uuid,p_status text,p_reason text) returns void language plpgsql security definer set search_path=public as $$
begin
 if not is_staff() then raise exception 'Staff only.'; end if;
 if p_status not in('Verified','Returned') then raise exception 'Status must be Verified or Returned.'; end if;
 if p_status='Returned' and coalesce(trim(p_reason),'')='' then raise exception 'A reason is required when returning evidence.'; end if;
 update submissions set verification_status=p_status,return_reason=case when p_status='Returned' then p_reason end,
  compliance='Not evaluated',deficiency_reasons=null,checks=null where id=p_id;
 perform log_h(p_id,'Verification: '||p_status,p_reason);
end $$;

create function _evaluate(p_id uuid) returns void language plpgsql security definer set search_path=public as $$
declare s submissions; p programs; c jsonb:='[]'; r text[]:='{}';
begin
 select * into s from submissions where id=p_id; if not found then raise exception 'Submission not found.'; end if;
 if s.verification_status<>'Verified' then raise exception 'Evidence must be Verified before evaluation.'; end if;
 select pr.* into p from assignments a join programs pr on pr.id=a.program_id where a.scholar_id=s.scholar_id;
 if not found then raise exception 'Scholar has no program assignment.'; end if;
 c:=c||jsonb_build_object('check','GWA at most '||p.max_gwa,'actual',s.gwa,'pass',s.gwa<=p.max_gwa);
 if s.gwa>p.max_gwa then r:=r||format('GWA %s exceeds maximum %s',s.gwa,p.max_gwa); end if;
 c:=c||jsonb_build_object('check','Units at least '||p.min_units,'actual',s.units,'pass',s.units>=p.min_units);
 if s.units<p.min_units then r:=r||format('Insufficient units (%s, minimum %s)',s.units,p.min_units); end if;
 c:=c||jsonb_build_object('check','Failed subjects at most '||p.max_failed,'actual',s.failed_count,'pass',s.failed_count<=p.max_failed);
 if s.failed_count>p.max_failed then r:=r||format('Failed subject (%s, allowed %s)',s.failed_count,p.max_failed); end if;
 c:=c||jsonb_build_object('check','Incomplete grades at most '||p.max_inc,'actual',s.incomplete_count,'pass',s.incomplete_count<=p.max_inc);
 if s.incomplete_count>p.max_inc then r:=r||format('Incomplete grade (%s, allowed %s)',s.incomplete_count,p.max_inc); end if;
 c:=c||jsonb_build_object('check','Dropped subjects at most '||p.max_drop,'actual',s.dropped_count,'pass',s.dropped_count<=p.max_drop);
 if s.dropped_count>p.max_drop then r:=r||format('Too many dropped subjects (%s, allowed %s)',s.dropped_count,p.max_drop); end if;
 c:=c||jsonb_build_object('check','Submitted by deadline','actual',to_char(s.submitted_at at time zone 'Asia/Manila','YYYY-MM-DD HH24:MI:SS'),'pass',s.submitted_at<=p.deadline);
 if s.submitted_at>p.deadline then r:=r||'Late submission'; end if;
 update submissions set checks=c,compliance=case when cardinality(r)=0 then 'Compliant' else 'With Deficiency' end,
  deficiency_reasons=case when cardinality(r)=0 then null else array_to_string(r,'; ') end where id=p_id;
 perform log_h(p_id,'Evaluated',case when cardinality(r)=0 then 'Compliant' else 'With Deficiency: '||array_to_string(r,'; ') end);
end $$;

create function evaluate_submission(p_id uuid) returns void language plpgsql security definer set search_path=public as $$
begin if not is_staff() then raise exception 'Staff only.'; end if; perform _evaluate(p_id); end $$;

create function decide_renewal(p_id uuid,p_decision text,p_note text) returns void language plpgsql security definer set search_path=public as $$
declare s submissions;
begin
 if not is_staff() then raise exception 'Staff only.'; end if;
 if p_decision not in('Approved','Held') then raise exception 'Decision must be Approved or Held.'; end if;
 select * into s from submissions where id=p_id; if not found then raise exception 'Submission not found.'; end if;
 if s.compliance='Not evaluated' then raise exception 'Verify and evaluate the submission before deciding renewal.'; end if;
 if p_decision='Approved' and s.compliance<>'Compliant' then raise exception 'Cannot approve a record With Deficiency. Hold it instead.'; end if;
 update submissions set renewal_decision=p_decision,decision_note=p_note where id=p_id;
 perform log_h(p_id,'Renewal: '||p_decision,p_note);
end $$;

revoke execute on function _evaluate(uuid), log_h(uuid,text,text), _check_input(text,int,numeric,int,int,int,int,text) from public, anon, authenticated;

-- Link or create a profile when someone signs up (pre-registered emails get linked).
create function handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin
 update profiles set auth_id=new.id where lower(email)=lower(new.email) and auth_id is null;
 if not found then insert into profiles(auth_id,email) values(new.id,lower(new.email)); end if;
 return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function handle_new_user();

-- Seed: six synthetic scholars (sign up as a01@exam.test etc. to log in as them). Submission times are Asia/Manila.
insert into profiles(email,full_name,student_id) values
 ('a01@exam.test','Ana Reyes','A01'),('a02@exam.test','Ben Cruz','A02'),('a03@exam.test','Cara Dizon','A03'),
 ('a04@exam.test','Dino Lim','A04'),('a05@exam.test','Ella Santos','A05'),('a06@exam.test','Finn Tan','A06');
insert into assignments select p.id,pr.id from profiles p join programs pr on pr.name=case when p.student_id in('A01','A02','A05') then 'Merit Scholar' else 'Community Scholar' end where p.student_id like 'A0%';
insert into submissions(scholar_id,academic_year,semester,gwa,units,failed_count,incomplete_count,dropped_count,evidence_ref,submitted_at,verification_status)
select p.id,'2026-2027',1,v.g,v.u,v.f,v.i,v.d,'DOC-'||v.sid,v.t::timestamptz,v.vs from (values
 ('A01',1.75,18,0,0,0,'2026-10-30 17:00:00+08','Verified'),('A02',1.76,18,0,0,0,'2026-10-29 17:00:00+08','Verified'),
 ('A03',2.25,15,0,0,1,'2026-10-29 17:00:00+08','Verified'),('A04',2.25,14,0,1,0,'2026-10-29 17:00:00+08','Verified'),
 ('A05',1.50,18,1,0,0,'2026-10-30 17:01:00+08','Verified'),('A06',2.00,15,0,0,0,'2026-10-29 17:00:00+08','Pending verification')
) as v(sid,g,u,f,i,d,t,vs) join profiles p on p.student_id=v.sid;
-- Make a staff account: sign up, then run: update profiles set role='staff' where email='staff@exam.test';