#!/usr/bin/env python3
"""Run with COLLAB_DIR=/tmp/a-fix python3 tests/regression.py (no real Codex calls)."""
import concurrent.futures
from contextlib import closing
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BASE = Path(os.environ.get('COLLAB_DIR', '/tmp/a-fix'))
BASE.mkdir(parents=True, exist_ok=True)

class Regression(unittest.TestCase):
    def setUp(self):
        self.path = Path(tempfile.mkdtemp(prefix='case-', dir=BASE))
        self.env = dict(os.environ, COLLAB_DIR=str(self.path))
        self.run_board('init')

    def run_board(self, *args, ok=True):
        p = subprocess.run(['bash', str(ROOT / 'board.sh'), *map(str,args)],
                           env=self.env, text=True, capture_output=True)
        if ok:
            self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        else:
            self.assertNotEqual(p.returncode, 0, p.stdout + p.stderr)
        return p.stdout.strip()

    def sql(self, statement):
        with closing(sqlite3.connect(self.path / 'board.db', timeout=10)) as db, db:
            return db.execute(statement).fetchall()

    def job(self, name, deps='', kind='test', priority=0):
        self.run_board('job-create', '--id', name, '--type', kind,
                       '--deps', deps, '--priority', priority)

    def agent(self, name='worker', session='s1'):
        self.run_board('agent-heartbeat','--agent',name,'--session',session,'--register')

    def claim(self, name, agent='worker'):
        self.run_board('job-ready')
        return self.run_board('job-claim','--id',name,'--agent',agent)

    def grant(self, name, token, agent='worker', session='s1'):
        return ['--id',name,'--token',token,'--agent',agent,'--session',session]

    def test_dependencies_cycles_and_atomic_rollback(self):
        self.job('A','B')
        self.run_board('job-ready')
        self.assertEqual(self.sql("SELECT status FROM jobs WHERE job_id='A'"), [('pending',)])
        self.run_board('job-create','--id','B','--type','test','--deps','A',ok=False)
        self.run_board('job-create','--id','self','--type','test','--deps','self',ok=False)
        self.assertEqual(self.sql("SELECT job_id FROM jobs"), [('A',)])
        self.job('B','C')
        self.run_board('job-create','--id','C','--type','test','--deps','A',ok=False)
        self.sql("CREATE TRIGGER reject_dep BEFORE INSERT ON job_deps WHEN NEW.dep_id='bad' BEGIN SELECT RAISE(ABORT,'injected dependency failure'); END")
        self.run_board('job-create','--id','rollback','--type','test','--deps','B,bad',ok=False)
        self.assertEqual(self.sql("SELECT job_id FROM jobs WHERE job_id='rollback'"), [])
        self.assertEqual(self.sql("SELECT * FROM job_deps WHERE job_id='rollback'"), [])

    def test_concurrent_ready_never_sees_partial_deps(self):
        # Every new job has a missing dependency; repeated concurrent readiness
        # scans must never release one, including during multi-edge insertion.
        def create(i):
            self.job('j'+str(i), ','.join('missing'+str(n) for n in range(50)))
        def scan():
            for _ in range(20): self.run_board('job-ready')
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            futures = [pool.submit(scan)] + [pool.submit(create,i) for i in range(15)]
            for f in futures: f.result()
        self.assertEqual(self.sql("SELECT count(*) FROM jobs WHERE status != 'pending'"), [(0,)])

    def test_dead_propagates_transitively_and_on_create(self):
        self.agent(); self.job('root'); self.job('child','root'); self.job('leaf','child')
        token = self.claim('root')
        self.sql("UPDATE jobs SET max_attempts=1 WHERE job_id='root'")
        self.run_board('job-fail',*self.grant('root',token))
        self.assertEqual(self.sql("SELECT count(*) FROM jobs WHERE status='dead'"), [(3,)])
        self.job('late','leaf')
        self.assertEqual(self.sql("SELECT status FROM jobs WHERE job_id='late'"), [('dead',)])

    def test_dependency_success_retry_and_atomic_effect(self):
        self.agent(); self.job('parent'); self.job('child','parent')
        token=self.claim('parent')
        self.run_board('job-fail',*self.grant('parent',token))
        self.run_board('job-ready')
        self.assertEqual(self.sql("SELECT status FROM jobs WHERE job_id='child'"),[('pending',)])
        token=self.claim('parent')
        self.sql("CREATE TRIGGER reject_done BEFORE UPDATE OF status ON jobs WHEN NEW.status='done' BEGIN SELECT RAISE(ABORT,'injected completion failure'); END")
        self.run_board('job-done',*self.grant('parent',token),'--effect','result',ok=False)
        self.assertEqual(self.sql('SELECT * FROM job_effects'),[])
        self.assertEqual(self.sql("SELECT status FROM jobs WHERE job_id='parent'"),[('running',)])
        self.sql('DROP TRIGGER reject_done')
        self.run_board('job-done',*self.grant('parent',token),'--effect','result')
        self.run_board('job-ready')
        self.assertEqual(self.sql("SELECT status FROM jobs WHERE job_id='child'"),[('ready',)])

    def test_start_owner_and_guard(self):
        token = self.run_board('start','task','alice')
        self.assertEqual(self.run_board('start','task','alice'),token)
        self.run_board('start','task','bob',ok=False)
        self.run_board('guard','task',ok=False)
        self.run_board('guard','task','--token',999,ok=False)
        self.run_board('guard','task','--token',token)
        self.run_board('state','task','failed','--token',token)
        self.assertGreater(int(self.run_board('start','task','bob')),int(token))

    def test_atomic_dispatch_and_capacity(self):
        self.agent(); self.job('one'); self.job('two'); self.run_board('job-ready')
        self.sql("CREATE TRIGGER reject_dispatch BEFORE INSERT ON messages BEGIN SELECT RAISE(ABORT,'injected bus failure'); END")
        self.run_board('job-claim','--id','one','--agent','worker',ok=False)
        self.assertEqual(self.sql("SELECT status FROM jobs WHERE job_id='one'"), [('ready',)])
        self.sql('DROP TRIGGER reject_dispatch')
        def attempt(name):
            return subprocess.run(['bash',str(ROOT/'board.sh'),'job-claim','--id',name,'--agent','worker'],env=self.env,capture_output=True).returncode
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(attempt, ['one','two']))
        self.assertEqual(sorted(results),[0,1])
        self.assertEqual(self.sql("SELECT count(*) FROM jobs WHERE status='running'"),[(1,)])
        self.assertEqual(self.sql("SELECT count(*) FROM messages WHERE type='task'"),[(1,)])
        self.assertEqual(self.sql("SELECT owner_session FROM jobs WHERE status='running'"),[('s1',)])

    def test_job_renew_guard_reap_and_session_replacement(self):
        self.agent(); self.job('one'); token=self.claim('one'); grant=self.grant('one',token)
        self.sql("UPDATE jobs SET lease_epoch=strftime('%s','now')+2")
        self.run_board('job-heartbeat',*grant)
        self.assertGreater(self.sql('SELECT lease_epoch FROM jobs')[0][0],time.time()+100)
        self.run_board('job-guard',*self.grant('one',token,session='wrong'),ok=False)
        self.run_board('job-done','--id','one','--token',token,ok=False)
        self.agent(session='s2')
        self.run_board('agent-heartbeat','--agent','worker','--session','s1',ok=False)
        self.run_board('job-heartbeat',*grant,ok=False)
        self.run_board('job-done',*grant,ok=False)
        self.run_board('job-reap')
        self.assertEqual(self.sql('SELECT status,attempts FROM jobs'),[('pending',1)])
        token2=self.claim('one')
        self.assertGreater(int(token2),int(token))
        self.sql("UPDATE agents SET expires=0")
        self.run_board('job-reap')
        self.assertEqual(self.sql('SELECT status,attempts FROM jobs'),[('pending',2)])
        self.agent(session='s3'); self.claim('one'); self.job('child','one')
        self.sql('UPDATE jobs SET lease_epoch=0 WHERE job_id=\'one\'')
        self.run_board('job-reap')
        self.assertEqual(self.sql("SELECT count(*) FROM jobs WHERE status='dead'"),[(2,)])

    def test_scheduler_skips_unroutable_and_caps_inflight(self):
        self.agent(); (self.path/'agents'/'worker.md').write_text('name: worker\nskills: test\n')
        self.job('blocked',kind='absent',priority=100)
        self.job('can-run',priority=2); self.job('later')
        p=subprocess.run(['bash',str(ROOT/'scheduler.sh'),'1'],env=self.env,capture_output=True,text=True)
        self.assertEqual(p.returncode,0,p.stderr)
        self.assertEqual(self.sql("SELECT job_id,status FROM jobs ORDER BY job_id"),
                         [('blocked','ready'),('can-run','running'),('later','ready')])

    def worker(self, seconds='0.2', lease='2'):
        env=dict(self.env,WORKER_MOCK_SECONDS=seconds,WORKER_HEARTBEAT_SECONDS='0.2',
                 WORKER_POLL_SECONDS='0.05',LEASE_SECONDS=lease)
        log=open(self.path/'worker.log','w')
        p=subprocess.Popen(['bash',str(ROOT/'agent-worker.sh'),'worker','100'],env=env,stdout=log,stderr=log)
        self.addCleanup(log.close)
        self.addCleanup(lambda: self.stop(p))
        self.until(lambda: self.sql('SELECT count(*) FROM agents')[0][0]==1)
        return p

    def stop(self,p):
        if p.poll() is None:
            p.terminate(); p.wait(timeout=5)

    def until(self,fn,timeout=10):
        end=time.monotonic()+timeout
        while time.monotonic()<end:
            if fn(): return
            time.sleep(.05)
        self.fail('timeout; '+(self.path/'worker.log').read_text() if (self.path/'worker.log').exists() else 'timeout')

    def test_worker_long_job_renewal_and_redelivery_idempotency(self):
        p=self.worker(seconds='3',lease='2'); self.job('long'); self.claim('long')
        self.until(lambda: self.sql("SELECT status FROM jobs")==[('done',)])
        self.assertEqual(self.sql('SELECT count(*) FROM job_effects'),[(1,)])
        self.sql("INSERT INTO messages(id,ts,from_agent,to_agent,type,task_id,summary) SELECT 'duplicate',ts,from_agent,to_agent,type,task_id,summary FROM messages LIMIT 1")
        self.until(lambda: self.sql('SELECT max(last_seq) FROM consumption')[0][0]==2)
        self.assertEqual(self.sql('SELECT count(*) FROM job_effects'),[(1,)])
        self.stop(p)

    def test_worker_stops_on_revocation_without_effect(self):
        p=self.worker(seconds='10'); self.job('revoked'); self.claim('revoked')
        self.until(lambda: '执行 job' in (self.path/'worker.log').read_text())
        self.agent(session='replacement')
        self.run_board('job-reap')
        p.wait(timeout=5)
        self.assertEqual(self.sql('SELECT * FROM job_effects'),[])
        self.assertEqual(self.sql('SELECT status FROM jobs'),[('pending',)])

    def test_bridge_parsing_failure_and_missing_grant(self):
        bindir=self.path/'bin'; bindir.mkdir()
        mock=bindir/'codex'
        mock.write_text('#!/bin/bash\necho called >> "$COLLAB_DIR/calls"\necho mock-output\nexit "${MOCK_RC:-0}"\n')
        mock.chmod(0o755)
        env=dict(self.env,PATH=str(bindir)+':'+os.environ['PATH'],CODEX_MAX_RETRIES='1')
        def bridge(args, rc, **extra):
            p=subprocess.run(['bash',str(ROOT/'codex-bridge.sh'),*args],env=dict(env,**extra),capture_output=True,text=True)
            self.assertEqual(p.returncode,rc,p.stdout+p.stderr)
        bridge(['--task-id','failed-task','think','neutral','prompt'],7,MOCK_RC='7')
        self.assertEqual(self.sql("SELECT status FROM tasks WHERE task_id='failed-task'"),[('failed',)])
        self.assertTrue((self.path/'output'/'failed-task.txt').exists())
        bridge(['--task-id=ok-task','think','neutral','prompt'],0)
        self.assertEqual(self.sql("SELECT status FROM tasks WHERE task_id='ok-task'"),[('done',)])
        self.run_board('start','owned','someone-else')
        bridge(['--task-id','owned','think','neutral','prompt'],1)
        bridge(['--task-id=ok-task','think','neutral','prompt'],1)
        bridge(['think','neutral','prompt','--task-id'],1)
        bridge(['--task-id','../escape','think','neutral','prompt'],1)
        self.assertEqual((self.path/'calls').read_text().splitlines(),['called','called'])

    def test_path_traversal_and_legacy_export(self):
        for name in ('../escape','a/b','/tmp/escape','..'):
            self.run_board('start',name,'owner',ok=False)
            self.run_board('handoff',name,'--from','worker',ok=False)
        self.sql("INSERT INTO tasks(task_id,status,updated_at) VALUES('../escape','done',0)")
        self.run_board('export',ok=False)
        self.assertFalse((self.path/'escape.json').exists())

    def test_schema_upgrade(self):
        self.sql('ALTER TABLE jobs DROP COLUMN owner_session')
        self.run_board('init'); self.run_board('init')
        self.assertIn('owner_session',[row[1] for row in self.sql('PRAGMA table_info(jobs)')])

if __name__=='__main__': unittest.main(verbosity=2)
