-- 請到 Supabase Dashboard -> SQL Editor 貼上並執行一次即可
-- 1. 新增錯題重做與加分欄位（向後相容既有 xueli-quiz）
ALTER TABLE public.submissions
  ADD COLUMN IF NOT EXISTS bonus_points integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS retry_answers integer[],
  ADD COLUMN IF NOT EXISTS retry_passed boolean,
  ADD COLUMN IF NOT EXISTS retry_at timestamptz;

-- 2. 重新編譯 teacher_get_submissions 以確保回傳新增欄位
CREATE OR REPLACE FUNCTION public.teacher_get_submissions(pw text)
RETURNS SETOF public.submissions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.teacher_config t WHERE t.pw = teacher_get_submissions.pw) THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;
  RETURN QUERY SELECT * FROM public.submissions WHERE NOT is_deleted ORDER BY created_at DESC;
END;
$$;

-- 3. 防止同一班級座號在同一天（台灣時間）重複送出同一課次測驗（僅針對 L%-chinese）
CREATE OR REPLACE FUNCTION public.prevent_duplicate_daily_lesson_submission()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  taipei_today date := (now() AT TIME ZONE 'Asia/Taipei')::date;
BEGIN
  IF NEW.exam_id LIKE 'L%-chinese' AND NOT COALESCE(NEW.is_deleted, false) THEN
    IF EXISTS (
      SELECT 1
      FROM public.submissions s
      WHERE s.exam_id = NEW.exam_id
        AND s.class = NEW.class
        AND s.seat = NEW.seat
        AND NOT s.is_deleted
        AND s.client_id IS DISTINCT FROM NEW.client_id
        AND (s.created_at AT TIME ZONE 'Asia/Taipei')::date = taipei_today
    ) THEN
      RAISE EXCEPTION 'already_submitted_today';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_prevent_duplicate_daily_lesson_submission ON public.submissions;
CREATE TRIGGER trg_prevent_duplicate_daily_lesson_submission
  BEFORE INSERT ON public.submissions
  FOR EACH ROW
  EXECUTE FUNCTION public.prevent_duplicate_daily_lesson_submission();

-- 4. 學生登入時檢查今日是否已考過該課測驗
CREATE OR REPLACE FUNCTION public.check_student_exam_status(
  p_exam_id text,
  p_class text,
  p_seat integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  taipei_today date := (now() AT TIME ZONE 'Asia/Taipei')::date;
  rec public.submissions%ROWTYPE;
BEGIN
  SELECT *
  INTO rec
  FROM public.submissions s
  WHERE s.exam_id = p_exam_id
    AND s.class = p_class
    AND s.seat = p_seat
    AND NOT s.is_deleted
    AND (s.created_at AT TIME ZONE 'Asia/Taipei')::date = taipei_today
  ORDER BY s.created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('found', false);
  END IF;

  RETURN jsonb_build_object(
    'found', true,
    'id', rec.id,
    'client_id', rec.client_id,
    'score', rec.score,
    'total', rec.total,
    'answers', rec.answers,
    'bonus_points', rec.bonus_points,
    'retry_passed', rec.retry_passed,
    'retry_answers', rec.retry_answers,
    'created_at', rec.created_at
  );
END;
$$;

-- 5. 送出個人錯題重做結果（限執行一次，原卷未滿分且重做全對加 10 分）
CREATE OR REPLACE FUNCTION public.submit_exam_retry(
  p_client_id text,
  p_retry_answers integer[],
  p_retry_passed boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  updated_id bigint;
  new_bonus integer;
BEGIN
  new_bonus := CASE WHEN p_retry_passed THEN 10 ELSE 0 END;

  UPDATE public.submissions
  SET retry_answers = p_retry_answers,
      retry_passed = p_retry_passed,
      bonus_points = new_bonus,
      retry_at = now()
  WHERE client_id = p_client_id
    AND NOT is_deleted
    AND retry_passed IS NULL
    AND score < total
  RETURNING id INTO updated_id;

  IF updated_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_retried_or_not_found');
  END IF;

  RETURN jsonb_build_object('ok', true, 'id', updated_id, 'bonus_points', new_bonus);
END;
$$;

GRANT EXECUTE ON FUNCTION public.check_student_exam_status(text, text, integer) TO anon;
GRANT EXECUTE ON FUNCTION public.submit_exam_retry(text, integer[], boolean) TO anon;
