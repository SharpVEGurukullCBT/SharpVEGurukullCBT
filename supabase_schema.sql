-- ============================================================================
-- SHARPVE GURUKULL CBT & DIAGNOSTIC PORTAL — SUPABASE SCHEMA & SECURE RPCs
-- Designed for Classes 06 to 12 (CBSE / RBSE), Jaipur
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 1. Students Roster (Roll No + 4-digit PIN + Optional Last Year Benchmark %)
CREATE TABLE IF NOT EXISTS public.cbt_students (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    roll_no TEXT UNIQUE NOT NULL,
    student_name TEXT NOT NULL,
    class_name TEXT NOT NULL CHECK (class_name IN ('Class 06','Class 07','Class 08','Class 09','Class 10','Class 11','Class 12')),
    board TEXT NOT NULL DEFAULT 'CBSE' CHECK (board IN ('CBSE','RBSE')),
    pin_code TEXT NOT NULL DEFAULT '1234',
    last_year_pct NUMERIC(5,2),
    parent_phone TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 2. Published Digital Tests (Stores answer key separately so student fetch never leaks answers)
CREATE TABLE IF NOT EXISTS public.cbt_tests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    test_code TEXT UNIQUE NOT NULL,
    title TEXT NOT NULL,
    class_name TEXT NOT NULL,
    subject TEXT NOT NULL,
    board TEXT NOT NULL DEFAULT 'CBSE',
    chapter TEXT NOT NULL,
    duration_mins INTEGER NOT NULL DEFAULT 20,
    negative_marking BOOLEAN NOT NULL DEFAULT FALSE,
    shuffle_questions BOOLEAN NOT NULL DEFAULT TRUE,
    window_start TIMESTAMPTZ,
    window_end TIMESTAMPTZ,
    is_published BOOLEAN NOT NULL DEFAULT TRUE,
    questions_public JSONB NOT NULL,   -- No correct_index or explanation here
    answer_key_secret JSONB NOT NULL,  -- Checked on server/RPC only
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3. Student Test Attempts (With Mid-Test Resume State + Final Diagnostic Breakdown)
CREATE TABLE IF NOT EXISTS public.cbt_attempts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    test_id UUID NOT NULL REFERENCES public.cbt_tests(id) ON DELETE CASCADE,
    test_code TEXT NOT NULL,
    student_id UUID NOT NULL REFERENCES public.cbt_students(id) ON DELETE CASCADE,
    roll_no TEXT NOT NULL,
    student_name TEXT NOT NULL,
    class_name TEXT NOT NULL,
    subject TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'IN_PROGRESS' CHECK (status IN ('IN_PROGRESS','SUBMITTED')),
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    submitted_at TIMESTAMPTZ,
    draft_answers JSONB NOT NULL DEFAULT '{}'::jsonb,
    draft_review JSONB NOT NULL DEFAULT '{}'::jsonb,
    score INTEGER NOT NULL DEFAULT 0,
    max_score INTEGER NOT NULL DEFAULT 0,
    percentage NUMERIC(5,2) NOT NULL DEFAULT 0,
    variety_stats JSONB NOT NULL DEFAULT '{}'::jsonb,
    topic_stats JSONB NOT NULL DEFAULT '{}'::jsonb,
    graded_items JSONB NOT NULL DEFAULT '[]'::jsonb
);

-- 4. Offline Marks (WTP / School Half-Yearly / School Pre-Board / Annual)
CREATE TABLE IF NOT EXISTS public.cbt_offline_marks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    roll_no TEXT NOT NULL,
    student_name TEXT NOT NULL,
    class_name TEXT NOT NULL,
    subject TEXT NOT NULL,
    assessment_type TEXT NOT NULL,
    marks_obtained NUMERIC(6,2) NOT NULL,
    max_marks NUMERIC(6,2) NOT NULL,
    percentage NUMERIC(5,2) NOT NULL,
    last_year_pct NUMERIC(5,2),
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Enable Row Level Security
ALTER TABLE public.cbt_students ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cbt_tests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cbt_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cbt_offline_marks ENABLE ROW LEVEL SECURITY;

-- Note: For production deployment, lock direct table reads/writes to authenticated/service roles
-- and expose controlled RPC functions below for student exam start, draft save, and graded submit.

-- RPC 1: Student Login & Fetch Test Paper WITHOUT Answer Keys
CREATE OR REPLACE FUNCTION public.cbt_start_or_resume_attempt(
    p_test_code TEXT,
    p_roll_no TEXT,
    p_pin TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_student public.cbt_students%ROWTYPE;
    v_test public.cbt_tests%ROWTYPE;
    v_attempt public.cbt_attempts%ROWTYPE;
    v_submitted_count INTEGER;
BEGIN
    SELECT * INTO v_student FROM public.cbt_students WHERE upper(roll_no) = upper(trim(p_roll_no));
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Student Roll No not found in SharpVE Gurukull roster.';
    END IF;
    IF v_student.pin_code <> trim(p_pin) THEN
        RAISE EXCEPTION 'Invalid PIN code.';
    END IF;

    SELECT * INTO v_test FROM public.cbt_tests WHERE upper(test_code) = upper(trim(p_test_code)) AND is_published = TRUE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Test code not found or not published.';
    END IF;

    IF v_test.window_start IS NOT NULL AND now() < v_test.window_start THEN
        RAISE EXCEPTION 'This test window has not opened yet.';
    END IF;
    IF v_test.window_end IS NOT NULL AND now() > v_test.window_end THEN
        RAISE EXCEPTION 'This test window has closed.';
    END IF;

    -- Prevent duplicate submission for same test
    SELECT count(*) INTO v_submitted_count
    FROM public.cbt_attempts
    WHERE test_id = v_test.id AND student_id = v_student.id AND status = 'SUBMITTED';
    IF v_submitted_count > 0 THEN
        RAISE EXCEPTION 'You have already submitted this test.';
    END IF;

    -- Resume existing IN_PROGRESS attempt if browser refreshed
    SELECT * INTO v_attempt
    FROM public.cbt_attempts
    WHERE test_id = v_test.id AND student_id = v_student.id AND status = 'IN_PROGRESS'
    ORDER BY started_at DESC LIMIT 1;

    IF NOT FOUND THEN
        INSERT INTO public.cbt_attempts(
            test_id, test_code, student_id, roll_no, student_name, class_name, subject,
            status, started_at, expires_at, max_score
        ) VALUES (
            v_test.id, v_test.test_code, v_student.id, v_student.roll_no, v_student.student_name,
            v_student.class_name, v_test.subject, 'IN_PROGRESS', now(),
            now() + make_interval(mins => v_test.duration_mins),
            jsonb_array_length(v_test.questions_public)
        ) RETURNING * INTO v_attempt;
    END IF;

    RETURN jsonb_build_object(
        'attempt_id', v_attempt.id,
        'student_name', v_student.student_name,
        'roll_no', v_student.roll_no,
        'class_name', v_student.class_name,
        'test_title', v_test.title,
        'subject', v_test.subject,
        'chapter', v_test.chapter,
        'shuffle_questions', v_test.shuffle_questions,
        'expires_at', v_attempt.expires_at,
        'draft_answers', v_attempt.draft_answers,
        'draft_review', v_attempt.draft_review,
        'questions', v_test.questions_public
    );
END;
$$;

-- RPC 2: Save Draft Answers on Refresh / Navigation
CREATE OR REPLACE FUNCTION public.cbt_save_draft(
    p_attempt_id UUID,
    p_draft_answers JSONB,
    p_draft_review JSONB
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE public.cbt_attempts
    SET draft_answers = COALESCE(p_draft_answers, '{}'::jsonb),
        draft_review = COALESCE(p_draft_review, '{}'::jsonb)
    WHERE id = p_attempt_id AND status = 'IN_PROGRESS';
END;
$$;

-- RPC 3: Server-Side Grading & Diagnostic Computation (Answers never exposed before submit)
CREATE OR REPLACE FUNCTION public.cbt_submit_attempt(
    p_attempt_id UUID,
    p_answers JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_attempt public.cbt_attempts%ROWTYPE;
    v_test public.cbt_tests%ROWTYPE;
    v_q JSONB;
    v_key JSONB;
    v_idx INTEGER := 0;
    v_total INTEGER;
    v_chosen_text TEXT;
    v_correct_idx INTEGER;
    v_score NUMERIC(6,2) := 0;
    v_correct_cnt INTEGER := 0;
    v_pct NUMERIC(5,2);
    v_variety TEXT;
    v_subtopic TEXT;
    v_is_correct BOOLEAN;
    v_v_stats JSONB := '{}'::jsonb;
    v_t_stats JSONB := '{}'::jsonb;
    v_items JSONB := '[]'::jsonb;
    v_vc INTEGER; v_vt INTEGER;
    v_tc INTEGER; v_tt INTEGER;
BEGIN
    SELECT * INTO v_attempt FROM public.cbt_attempts WHERE id = p_attempt_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Attempt not found.'; END IF;
    IF v_attempt.status = 'SUBMITTED' THEN
        RETURN jsonb_build_object(
            'attempt_id', v_attempt.id,
            'score', v_attempt.score,
            'total', v_attempt.max_score,
            'percentage', v_attempt.percentage,
            'variety_stats', v_attempt.variety_stats,
            'topic_stats', v_attempt.topic_stats,
            'items', v_attempt.graded_items
        );
    END IF;

    SELECT * INTO v_test FROM public.cbt_tests WHERE id = v_attempt.test_id;
    v_total := jsonb_array_length(v_test.questions_public);

    WHILE v_idx < v_total LOOP
        v_q := v_test.questions_public->v_idx;
        v_key := v_test.answer_key_secret->v_idx;
        v_correct_idx := COALESCE((v_key->>'correct_index')::int, 0);
        v_chosen_text := p_answers->>(v_idx::text);
        v_variety := COALESCE(v_q->>'variety', 'Standard MCQ');
        v_subtopic := COALESCE(v_q->>'subtopic', v_test.chapter);

        v_is_correct := (v_chosen_text IS NOT NULL AND v_chosen_text = (v_q->'options'->>v_correct_idx));

        IF v_is_correct THEN
            v_score := v_score + 1;
            v_correct_cnt := v_correct_cnt + 1;
        ELSIF v_test.negative_marking AND v_chosen_text IS NOT NULL AND length(trim(v_chosen_text)) > 0 THEN
            v_score := v_score - 0.25;
        END IF;

        -- Variety stats
        v_vc := COALESCE(((v_v_stats->v_variety)->>'correct')::int, 0) + CASE WHEN v_is_correct THEN 1 ELSE 0 END;
        v_vt := COALESCE(((v_v_stats->v_variety)->>'total')::int, 0) + 1;
        v_v_stats := jsonb_set(v_v_stats, ARRAY[v_variety], jsonb_build_object('correct', v_vc, 'total', v_vt));

        -- Topic stats
        v_tc := COALESCE(((v_t_stats->v_subtopic)->>'correct')::int, 0) + CASE WHEN v_is_correct THEN 1 ELSE 0 END;
        v_tt := COALESCE(((v_t_stats->v_subtopic)->>'total')::int, 0) + 1;
        v_t_stats := jsonb_set(v_t_stats, ARRAY[v_subtopic], jsonb_build_object('correct', v_tc, 'total', v_tt));

        v_items := v_items || jsonb_build_array(jsonb_build_object(
            'q_no', COALESCE((v_q->>'q_no')::int, v_idx + 1),
            'variety', v_variety,
            'subtopic', v_subtopic,
            'question_text', v_q->>'question_text',
            'chosen_text', COALESCE(v_chosen_text, 'Not Attempted'),
            'correct_text', v_q->'options'->>v_correct_idx,
            'is_correct', v_is_correct,
            'explanation', COALESCE(v_key->>'explanation', '')
        ));

        v_idx := v_idx + 1;
    END LOOP;

    IF v_score < 0 THEN v_score := 0; END IF;
    v_pct := CASE WHEN v_total > 0 THEN round((v_correct_cnt::numeric / v_total::numeric) * 100, 2) ELSE 0 END;

    UPDATE public.cbt_attempts
    SET status = 'SUBMITTED',
        submitted_at = now(),
        draft_answers = COALESCE(p_answers, '{}'::jsonb),
        score = round(v_score)::int,
        percentage = v_pct,
        variety_stats = v_v_stats,
        topic_stats = v_t_stats,
        graded_items = v_items
    WHERE id = p_attempt_id;

    RETURN jsonb_build_object(
        'attempt_id', p_attempt_id,
        'score', round(v_score)::int,
        'total', v_total,
        'percentage', v_pct,
        'variety_stats', v_v_stats,
        'topic_stats', v_t_stats,
        'items', v_items
    );
END;
$$;
