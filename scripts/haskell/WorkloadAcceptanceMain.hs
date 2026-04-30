module Main where

import qualified AwkernelWorkloadAcceptance as A
import Data.Char (isDigit)
import Data.List (intercalate)
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, stderr)

splitOn :: Char -> String -> [String]
splitOn delimiter = go []
  where
    go acc [] = [reverse acc]
    go acc (c:cs)
      | c == delimiter = reverse acc : go [] cs
      | otherwise = go (c : acc) cs

checkedNat :: String -> Integer -> Either String Integer
checkedNat label n
  | n >= 0 = Right n
  | otherwise = Left (label ++ " must be nonnegative")

checkedNatInteger :: String -> Integer -> Either String Integer
checkedNatInteger label n
  | n >= 0 = Right n
  | otherwise = Left (label ++ " must be nonnegative")

natCompare :: String -> (Integer -> Integer -> Bool) -> Integer -> Integer -> Bool
natCompare label op left right =
  case (checkedNatInteger (label ++ " left") left, checkedNatInteger (label ++ " right") right) of
    (Right leftInteger, Right rightInteger) -> leftInteger `op` rightInteger
    _ -> False

natFromField :: String -> Either String Integer
natFromField field
  | not (null field) && all isDigit field = checkedNat "natural number" (read field)
  | otherwise = Left ("expected natural number, got: " ++ show field)

isNatField :: String -> Bool
isNatField field = not (null field) && all isDigit field

optionNatFromField :: String -> Either String (A.Option A.JobId)
optionNatFromField "-" = Right A.None
optionNatFromField field = A.Some <$> natFromField field

boolFromField :: String -> Either String Bool
boolFromField "true" = Right True
boolFromField "false" = Right False
boolFromField field = Left ("expected boolean, got: " ++ show field)

listFromCsv :: String -> Either String (A.List A.JobId)
listFromCsv "" = Right A.Nil
listFromCsv csv = listFromFields (splitOn ',' csv)
  where
    listFromFields [] = Right A.Nil
    listFromFields (x:xs) = do
      headNat <- natFromField x
      tailNats <- listFromFields xs
      pure (A.Cons headNat tailNats)

optionListFromCsv :: String -> Either String (A.List (A.Option A.JobId))
optionListFromCsv "" = Right A.Nil
optionListFromCsv csv = listFromFields (splitOn ',' csv)
  where
    listFromFields [] = Right A.Nil
    listFromFields (x:xs) = do
      headNat <- optionNatFromField x
      tailNats <- listFromFields xs
      pure (A.Cons headNat tailNats)

boolListFromCsv :: String -> Either String (A.List Bool)
boolListFromCsv "" = Right A.Nil
boolListFromCsv csv = listFromFields (splitOn ',' csv)
  where
    listFromFields [] = Right A.Nil
    listFromFields (x:xs) = do
      headBool <- boolFromField x
      tailBools <- listFromFields xs
      pure (A.Cons headBool tailBools)

eventFromFields :: String -> String -> String -> Either String A.OpEvent
eventFromFields "Wakeup" a "-" = A.EvWakeup <$> natFromField a
eventFromFields "Block" a "-" = A.EvBlock <$> natFromField a
eventFromFields "RequestResched" a "-" = A.EvRequestResched <$> natFromField a
eventFromFields "HandleResched" a "-" = A.EvHandleResched <$> natFromField a
eventFromFields "Choose" a b = A.EvChoose <$> natFromField a <*> natFromField b
eventFromFields "Dispatch" a b = A.EvDispatch <$> natFromField a <*> natFromField b
eventFromFields "Complete" a "-" = A.EvComplete <$> natFromField a
eventFromFields "JoinTargetReady" a "-" = A.EvJoinTargetReady <$> natFromField a
eventFromFields "Stutter" "-" "-" = Right A.EvStutter
eventFromFields tag _ _ = Left ("unsupported event fields: " ++ show tag)

schedTraceEntryFromFields :: [String] -> Either String A.AwkernelSchedTraceEntry
schedTraceEntryFromFields [cpuField, eventTag, eventA, eventB, currentField, runnableCsv, needReschedField, dispatchField] =
  schedTraceEntryFromCoreFields
    "0"
    cpuField eventTag eventA eventB currentField runnableCsv needReschedField dispatchField
    currentField needReschedField dispatchField
schedTraceEntryFromFields [field0, field1, field2, field3, field4, field5, field6, field7, field8]
  | isNatField field1 =
      schedTraceEntryFromCoreFields
        field0
        field1 field2 field3 field4 field5 field6 field7 field8
        field5 field7 field8
  | otherwise =
      let candidatePrefixCsv = field8 in do
        _candidatePrefix <- listFromCsv candidatePrefixCsv
        schedTraceEntryFromCoreFields
          "0"
          field0 field1 field2 field3 field4 field5 field6 field7
          field4 field6 field7
schedTraceEntryFromFields [cpuField, eventTag, eventA, eventB, currentField, runnableCsv, needReschedField, dispatchField, workerCurrentCsv, workerNeedReschedCsv, workerDispatchCsv] =
  schedTraceEntryFromCoreFields
    "0"
    cpuField eventTag eventA eventB currentField runnableCsv needReschedField dispatchField
    workerCurrentCsv workerNeedReschedCsv workerDispatchCsv
schedTraceEntryFromFields [eventIdField, cpuField, eventTag, eventA, eventB, currentField, runnableCsv, needReschedField, dispatchField, candidatePrefixCsv] = do
  _candidatePrefix <- listFromCsv candidatePrefixCsv
  schedTraceEntryFromCoreFields
    eventIdField
    cpuField eventTag eventA eventB currentField runnableCsv needReschedField dispatchField
    currentField needReschedField dispatchField
schedTraceEntryFromFields [eventIdField, cpuField, eventTag, eventA, eventB, currentField, runnableCsv, needReschedField, dispatchField, workerCurrentCsv, workerNeedReschedCsv, workerDispatchCsv] =
  schedTraceEntryFromCoreFields
    eventIdField
    cpuField eventTag eventA eventB currentField runnableCsv needReschedField dispatchField
    workerCurrentCsv workerNeedReschedCsv workerDispatchCsv
schedTraceEntryFromFields fields =
  Left ("expected 8, 9, 10, 11, or 12 TSV sched_trace columns, got " ++ show (length fields) ++ " from " ++ show fields)

schedTraceEntryFromCoreFields :: String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> String -> Either String A.AwkernelSchedTraceEntry
schedTraceEntryFromCoreFields eventIdField cpuField eventTag eventA eventB currentField runnableCsv needReschedField dispatchField workerCurrentCsv workerNeedReschedCsv workerDispatchCsv = do
  eventId <- natFromField eventIdField
  cpu <- natFromField cpuField
  event <- eventFromFields eventTag eventA eventB
  current <- optionNatFromField currentField
  runnable <- listFromCsv runnableCsv
  needResched <- boolFromField needReschedField
  dispatch <- optionNatFromField dispatchField
  workerCurrent <- optionListFromCsv workerCurrentCsv
  workerNeedResched <- boolListFromCsv workerNeedReschedCsv
  workerDispatch <- optionListFromCsv workerDispatchCsv
  pure (A.MkAwkernelSchedTraceEntry eventId cpu event current runnable needResched dispatch workerCurrent workerNeedResched workerDispatch)

schedTraceFromLines :: Int -> [String] -> Either (Int, String) (A.List A.AwkernelSchedTraceEntry)
schedTraceFromLines _ [] = Right A.Nil
schedTraceFromLines index (line:rest)
  | null line = schedTraceFromLines (index + 1) rest
  | otherwise = do
      entry <- either (Left . (,) index) Right (schedTraceEntryFromFields (splitOn '\t' line))
      schedTrace <- schedTraceFromLines (index + 1) rest
      pure (A.Cons entry schedTrace)

taskTraceKindFromField :: String -> Either String A.AwkernelTaskTraceKind
taskTraceKindFromField "Spawn" = Right A.LkSpawn
taskTraceKindFromField "Runnable" = Right A.LkRunnable
taskTraceKindFromField "RunnableDeadline" = Right A.LkRunnableDeadline
taskTraceKindFromField "Choose" = Right A.LkChoose
taskTraceKindFromField "Dispatch" = Right A.LkDispatch
taskTraceKindFromField "Block" = Right A.LkBlock
taskTraceKindFromField "Unblock" = Right A.LkUnblock
taskTraceKindFromField "JoinWait" = Right A.LkJoinWait
taskTraceKindFromField "JoinTargetReady" = Right A.LkJoinTargetReady
taskTraceKindFromField "PeriodicJobComplete" = Right A.LkPeriodicJobComplete
taskTraceKindFromField "Complete" = Right A.LkComplete
taskTraceKindFromField field = Left ("unsupported task_trace kind: " ++ show field)

waitClassFromField :: String -> Either String (A.Option A.AwkernelWaitClass)
waitClassFromField "-" = Right A.None
waitClassFromField "Sleep" = Right (A.Some A.WcSleep)
waitClassFromField "Io" = Right (A.Some A.WcIo)
waitClassFromField "IO" = Right (A.Some A.WcIo)
waitClassFromField field = Left ("unsupported wait_class: " ++ show field)

unblockKindFromField :: String -> Either String (A.Option A.AwkernelUnblockKind)
unblockKindFromField "-" = Right A.None
unblockKindFromField "Ready" = Right (A.Some A.UkReady)
unblockKindFromField "Timeout" = Right (A.Some A.UkTimeout)
unblockKindFromField field = Left ("unsupported unblock_kind: " ++ show field)

taskPolicyFromFields :: String -> String -> Either String (A.Option A.AwkernelTaskPolicy)
taskPolicyFromFields "-" "-" = Right A.None
taskPolicyFromFields "PrioritizedFIFO" param =
  A.Some . A.AtpPrioritizedFIFO <$> natFromField param
taskPolicyFromFields "GlobalEDF" param =
  A.Some . A.AtpGlobalEDF <$> natFromField param
taskPolicyFromFields "PrioritizedRR" param =
  A.Some . A.AtpPrioritizedRR <$> natFromField param
taskPolicyFromFields "Panicked" "-" = Right (A.Some A.AtpPanicked)
taskPolicyFromFields _ _ = Right (A.Some A.AtpUnsupported)

taskTraceEntryFromFields :: [String] -> Either String A.AwkernelTaskTraceEntry
taskTraceEntryFromFields [eventIdField, kindField, subjectField, relatedField, waitClassField, unblockKindField, policyField, policyParamField] =
  taskTraceEntryFromCoreFields eventIdField kindField subjectField relatedField waitClassField unblockKindField policyField policyParamField A.None A.None
taskTraceEntryFromFields [eventIdField, kindField, subjectField, relatedField, waitClassField, unblockKindField, policyField, policyParamField, loopIndexField] = do
  loopIndex <- natFromField loopIndexField
  taskTraceEntryFromCoreFields
    eventIdField
    kindField
    subjectField
    relatedField
    waitClassField
    unblockKindField
    policyField
    policyParamField
    A.None
    (A.Some loopIndex)
taskTraceEntryFromFields [eventIdField, "PeriodicJobComplete", subjectField, relatedField, waitClassField, unblockKindField, policyField, policyParamField, loopIndexField, actualReleaseTimeField, executionTimeField] = do
  loopIndex <- natFromField loopIndexField
  _actualReleaseTime <- natFromField actualReleaseTimeField
  _executionTime <- natFromField executionTimeField
  taskTraceEntryFromCoreFields
    eventIdField
    "PeriodicJobComplete"
    subjectField
    relatedField
    waitClassField
    unblockKindField
    policyField
    policyParamField
    A.None
    (A.Some loopIndex)
taskTraceEntryFromFields [eventIdField, kindField, subjectField, relatedField, waitClassField, unblockKindField, policyField, policyParamField, wakeTimeField, absoluteDeadlineField] = do
  wakeTime <- natFromField wakeTimeField
  absoluteDeadline <- natFromField absoluteDeadlineField
  taskTraceEntryFromCoreFields
    eventIdField
    kindField
    subjectField
    relatedField
    waitClassField
    unblockKindField
    policyField
    policyParamField
    (A.Some (A.MkAwkernelRunnableDeadlineMetadata wakeTime absoluteDeadline A.None))
    A.None
taskTraceEntryFromFields [eventIdField, kindField, subjectField, relatedField, waitClassField, unblockKindField, policyField, policyParamField, wakeTimeField, absoluteDeadlineField, loopIndexField] = do
  wakeTime <- natFromField wakeTimeField
  absoluteDeadline <- natFromField absoluteDeadlineField
  loopIndex <- natFromField loopIndexField
  taskTraceEntryFromCoreFields
    eventIdField
    kindField
    subjectField
    relatedField
    waitClassField
    unblockKindField
    policyField
    policyParamField
    (A.Some (A.MkAwkernelRunnableDeadlineMetadata wakeTime absoluteDeadline (A.Some loopIndex)))
    (A.Some loopIndex)
taskTraceEntryFromFields fields =
  Left ("expected 8, 9, 10, or 11 TSV task_trace columns, got " ++ show (length fields) ++ " from " ++ show fields)

taskTraceEntryFromCoreFields :: String -> String -> String -> String -> String -> String -> String -> String -> A.Option A.AwkernelRunnableDeadlineMetadata -> A.Option Integer -> Either String A.AwkernelTaskTraceEntry
taskTraceEntryFromCoreFields eventIdField kindField subjectField relatedField waitClassField unblockKindField policyField policyParamField deadlineMetadata periodicLoopIndex = do
  eventId <- natFromField eventIdField
  kind <- taskTraceKindFromField kindField
  subject <- natFromField subjectField
  related <- optionNatFromField relatedField
  waitClass <- waitClassFromField waitClassField
  unblockKind <- unblockKindFromField unblockKindField
  policy <- taskPolicyFromFields policyField policyParamField
  pure (A.MkAwkernelTaskTraceEntry eventId kind subject related waitClass unblockKind policy deadlineMetadata periodicLoopIndex)

taskTraceFromLines :: Int -> [String] -> Either (Int, String) (A.List A.AwkernelTaskTraceEntry)
taskTraceFromLines _ [] = Right A.Nil
taskTraceFromLines index (line:rest)
  | null line = taskTraceFromLines (index + 1) rest
  | otherwise = do
      record <- either (Left . (,) index) Right (taskTraceEntryFromFields (splitOn '\t' line))
      records <- taskTraceFromLines (index + 1) rest
      pure (A.Cons record records)

data PeriodicCompletionTiming = PeriodicCompletionTiming
  { pctTask :: Integer
  , pctLoop :: Integer
  , pctActualReleaseTime :: Integer
  }

periodicCompletionTimingFromFields :: [String] -> Either String (Maybe PeriodicCompletionTiming)
periodicCompletionTimingFromFields [_, "PeriodicJobComplete", subjectField, _, _, _, _, _, loopIndexField, actualReleaseTimeField, executionTimeField] = do
  subject <- natFromField subjectField
  loopIndex <- natFromField loopIndexField
  actualReleaseTime <- natFromField actualReleaseTimeField
  _executionTime <- natFromField executionTimeField
  pure (Just (PeriodicCompletionTiming subject loopIndex actualReleaseTime))
periodicCompletionTimingFromFields fields =
  case taskTraceEntryFromFields fields of
    Left err -> Left err
    Right _ -> Right Nothing

periodicCompletionTimingsFromLines :: Int -> [String] -> Either (Int, String) [PeriodicCompletionTiming]
periodicCompletionTimingsFromLines _ [] = Right []
periodicCompletionTimingsFromLines index (line:rest)
  | null line = periodicCompletionTimingsFromLines (index + 1) rest
  | otherwise = do
      timing <- either (Left . (,) index) Right (periodicCompletionTimingFromFields (splitOn '\t' line))
      timings <- periodicCompletionTimingsFromLines (index + 1) rest
      pure (maybe timings (: timings) timing)

deadlineMetadataBefore :: Integer -> Integer -> Integer -> A.List A.AwkernelTaskTraceEntry -> Maybe A.AwkernelRunnableDeadlineMetadata
deadlineMetadataBefore _ _ _ A.Nil = Nothing
deadlineMetadataBefore eventId taskId loopIndex (A.Cons entry rest)
  | natCompare "event id" (>=) (A.atte_event_id entry) eventId = Nothing
  | otherwise =
      case A.atte_kind entry of
        A.LkRunnableDeadline
          | natCompare "task id" (==) (A.atte_subject entry) taskId ->
              case A.atte_deadline_metadata entry of
                A.Some metadata ->
                  case A.ardm_periodic_loop_index metadata of
                    A.Some metadataLoop
                      | natCompare "periodic loop index" (==) metadataLoop loopIndex ->
                          case deadlineMetadataBefore eventId taskId loopIndex rest of
                            Just laterMetadata -> Just laterMetadata
                            Nothing -> Just metadata
                    _ -> deadlineMetadataBefore eventId taskId loopIndex rest
                A.None -> deadlineMetadataBefore eventId taskId loopIndex rest
        _ -> deadlineMetadataBefore eventId taskId loopIndex rest

firstInvalidPeriodicCompletionTiming :: A.List A.AwkernelTaskTraceEntry -> [PeriodicCompletionTiming] -> Maybe Int
firstInvalidPeriodicCompletionTiming taskTrace timings = go 0 taskTrace
  where
    findTiming _ _ [] = Nothing
    findTiming taskId loopIndex (timing:rest)
      | natCompare "completion task id" (==) (pctTask timing) taskId &&
        natCompare "completion loop index" (==) (pctLoop timing) loopIndex = Just timing
      | otherwise = findTiming taskId loopIndex rest
    go _ A.Nil = Nothing
    go index (A.Cons entry rest) =
      case A.atte_kind entry of
        A.LkPeriodicJobComplete ->
          case A.atte_periodic_loop_index entry of
            A.Some loopIndex ->
              case findTiming (A.atte_subject entry) loopIndex timings of
                Just timing ->
                  case deadlineMetadataBefore (A.atte_event_id entry) (A.atte_subject entry) loopIndex taskTrace of
                    Just metadata
                      | natCompare "completion wake time" (>) (A.ardm_wake_time metadata) (pctActualReleaseTime timing) -> Just index
                    _ -> go (index + 1) rest
                Nothing -> go (index + 1) rest
            A.None -> go (index + 1) rest
        _ -> go (index + 1) rest

data Diagnostic = Diagnostic
  { accepted :: Bool
  , kind :: String
  , message :: String
  , schedTraceIndex :: Maybe Integer
  , taskTraceIndex :: Maybe Integer
  , logLineBegin :: Maybe Integer
  , logLineEnd :: Maybe Integer
  , backendLabel :: String
  , scenarioLabel :: Maybe String
  }

jsonEscape :: String -> String
jsonEscape = concatMap escapeChar
  where
    escapeChar '"' = "\\\""
    escapeChar '\\' = "\\\\"
    escapeChar '\n' = "\\n"
    escapeChar '\r' = "\\r"
    escapeChar '\t' = "\\t"
    escapeChar c = [c]

jsonField :: String -> String -> String
jsonField key value = "\"" ++ key ++ "\":" ++ value

jsonString :: String -> String
jsonString s = "\"" ++ jsonEscape s ++ "\""

jsonMaybeInteger :: Maybe Integer -> String
jsonMaybeInteger Nothing = "null"
jsonMaybeInteger (Just n) = show n

jsonMaybeString :: Maybe String -> String
jsonMaybeString Nothing = "null"
jsonMaybeString (Just s) = jsonString s

renderDiagnostic :: Diagnostic -> String
renderDiagnostic diag =
  "{" ++ intercalate "," fields ++ "}"
  where
    fields =
      [ jsonField "accepted" (if accepted diag then "true" else "false")
      , jsonField "backend" (jsonString (backendLabel diag))
      , jsonField "scenario" (jsonMaybeString (scenarioLabel diag))
      , jsonField "kind" (jsonString (kind diag))
      , jsonField "message" (jsonString (message diag))
      , jsonField "sched_trace_index" (jsonMaybeInteger (schedTraceIndex diag))
      , jsonField "task_trace_index" (jsonMaybeInteger (taskTraceIndex diag))
      , jsonField "log_line_begin" (jsonMaybeInteger (logLineBegin diag))
      , jsonField "log_line_end" (jsonMaybeInteger (logLineEnd diag))
      ]

emitDiagnostic :: Diagnostic -> IO ()
emitDiagnostic diag = do
  putStrLn (renderDiagnostic diag)
  let label = case scenarioLabel diag of
        Nothing -> backendLabel diag
        Just s -> backendLabel diag ++ "-" ++ s
      status = if accepted diag then "accepted" else "rejected"
  hPutStrLn stderr (label ++ ": " ++ status ++ ": " ++ message diag)

mkSuccess :: String -> Maybe String -> String -> Diagnostic
mkSuccess backend scenario scheduleLabel =
  Diagnostic
    { accepted = True
    , kind = "accepted"
    , message = "workload acceptance accepted the emitted task_trace/sched_trace pair under the logical top-1 " ++ scheduleLabel ++ " worker schedule"
    , schedTraceIndex = Nothing
    , taskTraceIndex = Nothing
    , logLineBegin = Nothing
    , logLineEnd = Nothing
    , backendLabel = backend
    , scenarioLabel = scenario
    }

mkFailure :: String -> Maybe String -> String -> String -> Maybe Integer -> Maybe Integer -> Diagnostic
mkFailure backend scenario diagKind diagMessage schedTraceIx taskTraceIx =
  Diagnostic
    { accepted = False
    , kind = diagKind
    , message = diagMessage
    , schedTraceIndex = schedTraceIx
    , taskTraceIndex = taskTraceIx
    , logLineBegin = Nothing
    , logLineEnd = Nothing
    , backendLabel = backend
    , scenarioLabel = scenario
    }

main :: IO ()
main = do
  args <- getArgs
  let (backend, scenarioRaw, schedTracePath, taskTracePath) = case args of
        (w:x:y:z:_) -> (w, x, y, z)
        _ -> ("backend", "-", "", "")
      scenario = if scenarioRaw == "-" then Nothing else Just scenarioRaw
  if null schedTracePath || null taskTracePath
    then do
      emitDiagnostic
        (mkFailure backend scenario "internal-checker-error"
          "expected arguments <backend> <scenario-or--> <sched-trace-file> <task-trace-file>"
          Nothing Nothing)
      exitFailure
    else do
      schedTraceInput <- readFile schedTracePath
      taskTraceInput <- readFile taskTracePath
      case schedTraceFromLines 0 (lines schedTraceInput) of
        Left (idx, err) -> do
          emitDiagnostic
            (mkFailure backend scenario "sched-trace-parse-failure"
              ("failed to parse extracted sched_trace: " ++ err)
              (Just (fromIntegral idx)) Nothing)
          exitFailure
        Right schedTrace ->
          case taskTraceFromLines 0 (lines taskTraceInput) of
            Left (idx, err) -> do
              emitDiagnostic
                (mkFailure backend scenario "task-trace-parse-failure"
                  ("failed to parse extracted task_trace: " ++ err)
                  Nothing (Just (fromIntegral idx)))
              exitFailure
            Right taskTrace ->
              case periodicCompletionTimingsFromLines 0 (lines taskTraceInput) of
                Left (idx, err) -> do
                  emitDiagnostic
                    (mkFailure backend scenario "task-trace-parse-failure"
                      ("failed to parse extracted task_trace periodic completion timing metadata: " ++ err)
                      Nothing (Just (fromIntegral idx)))
                  exitFailure
                Right periodicCompletionTimings ->
                  case firstInvalidPeriodicCompletionTiming taskTrace periodicCompletionTimings of
                    Just timingIdx -> do
                      emitDiagnostic
                        (mkFailure backend scenario "edf-deadline-metadata-rejection"
                          "the emitted PeriodicJobComplete timing metadata precedes the logical RunnableDeadline wake_time"
                          Nothing (Just (fromIntegral timingIdx)))
                      exitFailure
                    Nothing ->
                      case A.first_non_edf_fifo_task_policy_index taskTrace of
                        A.Some policyIdx -> do
                          emitDiagnostic
                            (mkFailure backend scenario "unsupported-policy-rejection"
                              "the emitted task_trace requests a policy that this adapter checker does not support"
                              Nothing (Just policyIdx))
                          exitFailure
                        A.None ->
                          case A.first_invalid_runnable_deadline_task_trace_index taskTrace of
                            A.Some deadlineIdx -> do
                              emitDiagnostic
                                (mkFailure backend scenario "edf-deadline-metadata-rejection"
                                  "the emitted task_trace has invalid RunnableDeadline metadata for the EDF/FIFO policy"
                                  Nothing (Just deadlineIdx))
                              exitFailure
                            A.None ->
                              case A.awk_workload_accepts_sched_trace taskTrace schedTrace of
                                False -> do
                                  emitDiagnostic
                                    (mkFailure backend scenario "workload-family-rejection"
                                      "workload acceptance rejected the emitted task_trace/sched_trace pair"
                                      Nothing Nothing)
                                  exitFailure
                                True ->
                                  case A.task_trace_all_global_fifo_policyb taskTrace of
                                    True ->
                                      case A.first_non_scheduler_relation_sched_trace_index taskTrace schedTrace of
                                        A.None -> do
                                          emitDiagnostic (mkSuccess backend scenario "GlobalFIFO")
                                          exitSuccess
                                        A.Some relationIdx ->
                                          case A.first_non_fifo_sched_trace_index schedTrace of
                                            A.Some fifoIdx
                                              | fifoIdx == relationIdx -> do
                                                  emitDiagnostic
                                                    (mkFailure backend scenario "global-fifo-rejection"
                                                      "the emitted sched_trace violates the local GlobalFIFO choose-order check for the logical top-1 worker schedule"
                                                      (Just fifoIdx) Nothing)
                                                  exitFailure
                                            _ -> do
                                              emitDiagnostic
                                                (mkFailure backend scenario "scheduler-relation-rejection"
                                                  "the emitted sched_trace violates the extracted GlobalFIFO scheduler-relation check for the logical top-1 worker schedule"
                                                  (Just relationIdx) Nothing)
                                              exitFailure
                                    False ->
                                      case A.first_non_edf_fifo_scheduler_relation_sched_trace_index taskTrace schedTrace of
                                        A.None -> do
                                          emitDiagnostic (mkSuccess backend scenario "EDF/FIFO")
                                          exitSuccess
                                        A.Some relationIdx -> do
                                          emitDiagnostic
                                            (mkFailure backend scenario "edf-fifo-rejection"
                                              "the emitted sched_trace violates the extracted EDF/FIFO scheduler-relation check for the logical top-1 worker schedule"
                                              (Just relationIdx) Nothing)
                                          exitFailure
