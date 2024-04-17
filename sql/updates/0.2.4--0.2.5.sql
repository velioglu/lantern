
DROP TRIGGER IF EXISTS status_change_trigger ON cron.job_run_details;
DROP FUNCTION IF EXISTS _lantern_internal.async_task_finalizer_trigger();

DO $async_update$

BEGIN
  IF NOT (SELECT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'cron'))
  THEN
    RAISE NOTICE 'pg_cron extension not found. Skipping lantern async task setup';
    RETURN;
  END IF;

  GRANT USAGE ON SCHEMA cron TO PUBLIC;
  GRANT SELECT, INSERT, UPDATE, DELETE ON lantern.tasks TO public;
  GRANT USAGE, SELECT ON SEQUENCE lantern.tasks_jobid_seq TO public;

  -- create a trigger and added to cron.job_run_details
  CREATE OR REPLACE FUNCTION _lantern_internal.async_task_finalizer_trigger() RETURNS TRIGGER AS $$
  DECLARE
    res RECORD;
  BEGIN
    -- if NEW.status is one of "starting", "running", "sending, "connecting", return
    IF NEW.status IN ('starting', 'running', 'sending', 'connecting') THEN
      RETURN NEW;
    END IF;

    IF NEW.status NOT IN ('succeeded', 'failed') THEN
      RAISE WARNING 'Lantern Async tasks: Unexpected status %', NEW.status;
    END IF;

    -- Get the job name from the jobid
    -- Call the job finalizer if corresponding job exists BOTH in lantern async tasks AND
    -- active cron jobs
    UPDATE lantern.tasks t SET
        (duration, status, error_message, pg_cron_job_name) = (run.end_time - t.started_at, NEW.status,
        CASE WHEN NEW.status = 'failed' THEN return_message ELSE NULL END,
        c.jobname )
    FROM cron.job c
    LEFT JOIN cron.job_run_details run
    ON c.jobid = run.jobid
    WHERE
       t.pg_cron_job_name = c.jobname AND
       c.jobid = NEW.jobid
    -- using returning as a trick to run the unschedule function as a side effect
    -- Note: have to unschedule by jobid because of pg_cron#320 https://github.com/citusdata/pg_cron/issues/320
    RETURNING cron.unschedule(t.jobid) INTO res;

    RETURN NEW;

  EXCEPTION
     WHEN OTHERS THEN
          RAISE WARNING 'Lantern Async tasks: Unknown job failure in % % %', NEW, SQLERRM, SQLSTATE;
          PERFORM cron.unschedule(NEW.jobid);
          RETURN NEW;
  END
  $$ LANGUAGE plpgsql;

  CREATE TRIGGER status_change_trigger
  AFTER UPDATE OF status
  ON cron.job_run_details
  FOR EACH ROW
  WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION _lantern_internal.async_task_finalizer_trigger();

$async_update$
LANGUAGE plpgsql;

-- helper function to mask large vectors in explain outputs of queries containing vectors
CREATE OR REPLACE FUNCTION lantern.masked_explain(
        query text,
        do_analyze boolean = true,
        buffers boolean = true,
        costs boolean = true,
        timing boolean = true
) RETURNS text AS $$
DECLARE
    explain_query text;
    explain_output jsonb;
    flags text = '';
BEGIN
    IF do_analyze THEN
      flags := flags || 'ANALYZE, ';
    END IF;
    IF buffers THEN
      flags := flags || 'BUFFERS, ';
    END IF;
    IF costs THEN
      flags := flags || 'COSTS, ';
    END IF;
    IF timing THEN
      flags := flags || 'TIMING ';
    END IF;
    explain_query := format('EXPLAIN (%s, FORMAT JSON) %s', flags, query);
    EXECUTE explain_query INTO explain_output;
    RETURN jsonb_pretty(_lantern_internal.mask_order_by_in_plan(explain_output));
END $$ LANGUAGE plpgsql;