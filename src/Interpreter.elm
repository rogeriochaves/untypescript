module Interpreter exposing (LineResult, State, emptyState, run)

import Dict exposing (Dict)
import Fuzz exposing (result)
import Html exposing (ins)
import List.Extra
import Parser exposing (Problem(..))
import Return
import Test.Runner.Failure exposing (Reason(..))
import Tuple
import Types exposing (..)


type alias State =
    { variables : Dict String Value
    }


emptyState : State
emptyState =
    { variables = Dict.empty
    }


type alias LineResult =
    { outScope : State, inScope : State, result : Value }


run : State -> Types.Program -> ( State, List LineResult )
run state expressions =
    let
        iterate_ : Expression -> ( State, State, List LineResult ) -> ( State, State, List LineResult )
        iterate_ expr ( outScope, inScope, lineResults ) =
            let
                ( resultOutScope, resultInScope, expressionResult ) =
                    iterate expr ( outScope, inScope )
            in
            ( resultOutScope, resultInScope, expressionResult :: lineResults )
    in
    expressions
        |> List.foldl iterate_ ( state, emptyState, [] )
        |> (\( outScope, inScope, results ) ->
                ( mergeStates inScope outScope
                , List.reverse results
                )
           )


runBlock : State -> List Expression -> ( State, Maybe Value )
runBlock state blockExpressions =
    let
        iterate_ : Expression -> ( State, State, Maybe Value ) -> ( State, State, Maybe Value )
        iterate_ expr ( outScope, inScope, returnValue ) =
            if returnValue == Nothing then
                let
                    ( resultOutScope, resultInScope, expressionResult ) =
                        iterate expr ( outScope, inScope )

                    returnValue_ =
                        case expr |> removeTracking of
                            Return _ ->
                                Just expressionResult.result

                            _ ->
                                Nothing
                in
                ( resultOutScope, resultInScope, returnValue_ )

            else
                ( outScope, inScope, returnValue )
    in
    -- TODO: return last if outside function? (right now returns void)
    blockExpressions
        |> List.foldl iterate_ ( state, emptyState, Nothing )
        |> (\( outScope, _, returnValue ) -> ( outScope, returnValue ))


runExpression : State -> Expression -> LineResult
runExpression state expr =
    let
        trackStack : UndefinedReason -> List UndefinedTrackInfo
        trackStack reason =
            case expr of
                Tracked info _ ->
                    [ { column = info.column, line = info.line, filename = info.filename, reason = reason } ]

                _ ->
                    []

        return result =
            { outScope = emptyState, inScope = emptyState, result = result }
    in
    case expr |> removeTracking of
        Value (Vector items) ->
            Debug.todo "vector not supported yet"

        -- let
        --     appendOrLiftError : Value -> Value -> Value
        --     appendOrLiftError curr acc =
        --         case ( acc, curr ) of
        --             ( Vector items_, e ) ->
        --                 Vector (items_ ++ [ e ])
        --             _ ->
        --                 acc
        -- in
        -- return
        --     (evalList items state
        --         -- TODO: do not ignore state updates
        --         |> (\( _, _, results ) -> results)
        --         |> List.foldl appendOrLiftError (Vector [])
        --     )
        Value val ->
            return val

        Variable identifier ->
            return
                (Dict.get identifier state.variables
                    |> Maybe.withDefault (Undefined (trackStack <| VariableNotDefined identifier))
                )

        Operation symbol expr0 ->
            statefulSession state identity
                |> thenCapture expr0
                |> thenRun
                    (\arg0 ->
                        applyOperation symbol arg0
                    )
                |> unwrap

        Operation2 symbol expr0 expr1 ->
            statefulSession state Tuple.pair
                |> thenCapture expr0
                |> thenCapture expr1
                |> thenRun
                    (\( arg0, arg1 ) ->
                        applyOperation2 symbol arg0 arg1 trackStack
                    )
                |> unwrap

        Application fn args ->
            let
                ( outScope, inScope, evaluatedArgs ) =
                    evalList args state

                state_ =
                    mergeStates inScope (mergeStates outScope state)

                applicationResult =
                    case eval state fn  of
                        (Abstraction paramNames functionBody) ->
                            callFunction state_ trackStack ( paramNames, functionBody ) evaluatedArgs

                        (Undefined stacktrace) ->
                            return (Undefined stacktrace)

                        _ ->
                            Debug.todo "not implemented"
            in
            applicationResult
                |> preprendStateChanges outScope inScope

        Block blockExpressions ->
            let
                ( outScope, result ) =
                    runBlock state blockExpressions
            in
            LineResult outScope
                emptyState
                (result
                    |> Maybe.withDefault (Undefined (trackStack VoidReturn))
                )

        Return returnExpr ->
            runExpression state returnExpr

        IfCondition condition exprIfTrue ->
            statefulSession state valueToBool
                |> thenCapture condition
                |> thenExecute
                    (\result ->
                        if result then
                            exprIfTrue

                        else
                            Untracked (Value (Undefined (trackStack IfWithoutElse)))
                    )
                |> unwrap

        While condition exprWhile ->
            statefulSession state valueToBool
                |> thenCapture condition
                |> thenExecute
                    (\result ->
                        if result then
                            exprWhile

                        else
                            Untracked (Value (Undefined (trackStack LoopNeverTrue)))
                    )
                |> thenExecute
                    (\result ->
                        if result then
                            Untracked (While condition exprWhile)

                        else
                            -- TODO: while should return last value instead of undefined
                            Untracked (Value (Undefined (trackStack LoopNeverTrue)))
                    )
                |> unwrap


preprendStateChanges : State -> State -> LineResult -> LineResult
preprendStateChanges outScope inScope result =
    LineResult
        (mergeStates result.outScope outScope)
        (mergeStates result.inScope inScope)
        result.result


mergeStates : State -> State -> State
mergeStates a b =
    { variables = Dict.union a.variables b.variables }


type StatefulResult a
    = StatefulResult a ( State, State, LineResult )


statefulSession : State -> a -> StatefulResult a
statefulSession state a =
    StatefulResult a
        ( state
        , emptyState
        , { outScope = emptyState
          , inScope = emptyState
          , result = Undefined []
          }
        )


thenCapture : Expression -> StatefulResult (Value -> b) -> StatefulResult b
thenCapture expr (StatefulResult fn ( prevOutScope, prevInScope, _ )) =
    let
        tripleResult =
            iterate expr ( prevOutScope, prevInScope )

        ( _, _, result ) =
            tripleResult
    in
    StatefulResult (fn result.result) tripleResult


thenRun : (a -> LineResult) -> StatefulResult a -> StatefulResult ()
thenRun fn (StatefulResult a ( prevOutScope, prevInScope, _ )) =
    let
        expressionResult =
            fn a
                |> preprendStateChanges prevOutScope emptyState

        -- TODO: remove this duplication with iterate_
        outScopeFiltered =
            mergeStates
                { variables =
                    Dict.filter
                        (\identifier _ ->
                            not (Dict.member identifier prevInScope.variables)
                        )
                        expressionResult.outScope.variables
                }
                prevOutScope

        inScopeUpdated =
            mergeStates
                { variables =
                    Dict.filter
                        (\identifier _ ->
                            Dict.member identifier prevInScope.variables
                        )
                        expressionResult.outScope.variables
                }
                (mergeStates expressionResult.inScope prevInScope)
    in
    StatefulResult () ( outScopeFiltered, inScopeUpdated, expressionResult )


thenExecute : (a -> Expression) -> StatefulResult a -> StatefulResult a
thenExecute fn (StatefulResult a ( prevOutScope, prevInScope, _ )) =
    StatefulResult a (iterate (fn a) ( prevOutScope, prevInScope ))


unwrap : StatefulResult a -> LineResult
unwrap (StatefulResult _ ( prevOutScope, prevInScope, expressionResult )) =
    let
        -- TODO: remove this duplication with iterate_
        outScopeFiltered =
            mergeStates
                { variables =
                    Dict.filter
                        (\identifier _ ->
                            not (Dict.member identifier prevInScope.variables)
                        )
                        expressionResult.outScope.variables
                }
                prevOutScope

        inScopeUpdated =
            mergeStates
                { variables =
                    Dict.filter
                        (\identifier _ ->
                            Dict.member identifier prevInScope.variables
                        )
                        expressionResult.outScope.variables
                }
                (mergeStates expressionResult.inScope prevInScope)
    in
    LineResult outScopeFiltered inScopeUpdated expressionResult.result


iterate : Expression -> ( State, State ) -> ( State, State, LineResult )
iterate expr ( prevOutScope, prevInScope ) =
    let
        state =
            mergeStates prevInScope prevOutScope

        expressionResult =
            runExpression state expr

        outScopeFiltered =
            mergeStates
                { variables =
                    Dict.filter
                        (\identifier _ ->
                            not (Dict.member identifier prevInScope.variables)
                        )
                        expressionResult.outScope.variables
                }
                prevOutScope

        inScopeUpdated =
            mergeStates
                { variables =
                    Dict.filter
                        (\identifier _ ->
                            Dict.member identifier prevInScope.variables
                        )
                        expressionResult.outScope.variables
                }
                (mergeStates expressionResult.inScope prevInScope)
    in
    ( outScopeFiltered, inScopeUpdated, expressionResult )


evalList : List Expression -> State -> ( State, State, List Value )
evalList expressions state =
    let
        iterate_ : Expression -> ( State, State, List Value ) -> ( State, State, List Value )
        iterate_ expr ( outScope, inScope, results ) =
            let
                ( resultOutScope, resultInScope, expressionResult ) =
                    iterate expr ( outScope, inScope )
            in
            ( resultOutScope, resultInScope, expressionResult.result :: results )
    in
    expressions
        |> List.foldl iterate_
            ( state
            , emptyState
            , []
            )
        |> (\( a, b, results ) -> ( a, b, List.reverse results ))


applyOperation : Operation -> Value -> LineResult
applyOperation operation arg0 =
    case operation of
        Assignment name ->
            LineResult
                { variables = Dict.fromList [ ( name, arg0 ) ] }
                emptyState
                arg0

        LetAssignment name ->
            LineResult
                emptyState
                { variables = Dict.fromList [ ( name, arg0 ) ] }
                arg0


applyOperation2 : Operation2 -> Value -> Value -> (UndefinedReason -> List UndefinedTrackInfo) -> LineResult
applyOperation2 reserved arg0 arg1 trackStack =
    let
        return result =
            { outScope = emptyState, inScope = emptyState, result = result }
    in
    case reserved of
        Addition ->
            return (Return.mapNumArgs2 (trackStack (OperationWithUndefined "addition")) (+) Number arg0 arg1)

        Subtraction ->
            return (Return.mapNumArgs2 (trackStack (OperationWithUndefined "subtraction")) (-) Number arg0 arg1)

        SoftEquality ->
            let
                trackStack_ =
                    trackStack (OperationWithUndefined "equality")
            in
            return
                (case ( arg0, arg1 ) of
                    ( Number a, Number b ) ->
                        Boolean (a == b)

                    ( Boolean a, v ) ->
                        Boolean (comparisonWithBool v a)

                    ( v, Boolean a ) ->
                        Boolean (comparisonWithBool v a)

                    ( Undefined stack, _ ) ->
                        Undefined (stack ++ trackStack_)

                    ( _, Undefined stack ) ->
                        Undefined (stack ++ trackStack_)

                    _ ->
                        -- TODO: what about true == 1? 0 == false? "1" == 1
                        Undefined trackStack_
                )

        GreaterThan ->
            return
                (case ( arg0, arg1 ) of
                    ( Number a, Number b ) ->
                        Boolean (a > b)

                    ( Number a, Boolean b ) ->
                        Boolean (a > boolToNumber b)

                    ( Boolean a, Number b ) ->
                        Boolean (boolToNumber a > b)

                    _ ->
                        Boolean False
                )

        SmallerThan ->
            return
                (case ( arg0, arg1 ) of
                    ( Number a, Number b ) ->
                        Boolean (a < b)

                    ( Number a, Boolean b ) ->
                        Boolean (a < boolToNumber b)

                    ( Boolean a, Number b ) ->
                        Boolean (boolToNumber a < b)

                    _ ->
                        Boolean False
                )


comparisonWithBool : Value -> Bool -> Bool
comparisonWithBool value bool =
    case value of
        Boolean a ->
            a == bool

        Number a ->
            if a == 0 then
                False == bool

            else if a == 1 then
                True == bool

            else
                False

        Abstraction _ _ ->
            False

        Vector _ ->
            Debug.todo "not implemented"

        Undefined _ ->
            False


valueToBool : Value -> Bool
valueToBool value =
    case value of
        Boolean a ->
            a

        Number a ->
            if a == 0 then
                False

            else
                True

        Abstraction _ _ ->
            True

        Vector _ ->
            Debug.todo "not implemented"

        Undefined _ ->
            False


boolToNumber : Bool -> Float
boolToNumber bool =
    if bool then
        1

    else
        0



-- runSingleArity : State -> SingleArity -> Expression -> LineResult
-- runSingleArity state func expr =
--     case func of
--         Assignment identifier ->
--             case identifier of
--                 ScalarIdentifier name ->
--                     case eval state expr of
--                         Expression (Number num) ->
--                             ( setVariable name num state, Expression (Number num) )
--                         Expression (Vector _) ->
--                             ( state, throwError ("Cannot assign vector to scalar variables, use \\vec{" ++ name ++ "} instead") )
--                         Undefined ->
--                             ( state, throwError ("Cannot set variable " ++ name ++ " to Undefined") )
--                         Error error ->
--                             ( state, Error error )
--                         Expression (Abstraction params body) ->
--                             ( setFunction name params body state, Undefined )
--                         Expression (MapAbstraction params index body) ->
--                             ( setMapFunction name params index body state, Undefined )
--                         Expression e ->
--                             ( state, Expression (SingleArity (Assignment identifier) e) )
--                 VectorIdentifier name ->
--                     case eval state expr of
--                         Expression (Number _) ->
--                             ( state, throwError "Cannot assign scalar to vector variables" )
--                         Expression (Vector v) ->
--                             ( setVector name v state, Expression (Vector v) )
--                         Undefined ->
--                             ( state, throwError ("Cannot set variable " ++ name ++ " to Undefined") )
--                         Error error ->
--                             ( state, Error error )
--                         Expression e ->
--                             ( state, Expression (SingleArity (Assignment identifier) e) )
--         Application e1 ->
--             case eval state e1 of
--                 Expression (Variable (ScalarIdentifier name)) ->
--                     ( state
--                     , case ( Dict.get name state.mapFunctions, Dict.get name state.functions ) of
--                         ( Just mapFn, _ ) ->
--                             callMapFunction func state expr mapFn
--                         ( Nothing, Just fn ) ->
--                             callFunction func state expr fn
--                         ( Nothing, Nothing ) ->
--                             eval state expr
--                                 |> Return.andThenNum (SingleArity func) (Expression << SingleArity func << Number)
--                     )
--                 _ ->
--                     Debug.todo "not implemented"
--         Sqrt ->
--             ( state
--             , eval state expr
--                 |> Return.mapNum (SingleArity func) sqrt
--             )
--         Factorial ->
--             let
--                 factorial : Float -> Value
--                 factorial num =
--                     if not (isInteger num) || num < 0 then
--                         throwError ("Cannot calculate factorial for " ++ String.fromFloat num ++ ", only for positive integers")
--                     else
--                         List.range 1 (round num)
--                             |> List.foldl (*) 1
--                             |> (Expression << Number << toFloat)
--             in
--             ( state
--             , eval state expr
--                 |> Return.andThenNum (SingleArity func) factorial
--             )
--         Negation ->
--             ( state
--             , eval state expr
--                 |> Return.mapNum (SingleArity func) negate
--             )
--         Summation ->
--             ( state
--             , eval state expr
--                 |> Return.andThenVector (SingleArity func)
--                     (List.foldl
--                         (\curr acc ->
--                             case acc of
--                                 Expression (Number n) ->
--                                     if n == 0 then
--                                         Expression curr
--                                     else
--                                         Expression (DoubleArity Addition (Number n) curr)
--                                 Expression e ->
--                                     Expression (DoubleArity Addition e curr)
--                                 acc_ ->
--                                     acc_
--                         )
--                         (Expression (Number 0))
--                         >> Return.andThen (eval state)
--                     )
--             )
--         Cardinality ->
--             ( state
--             , eval state expr
--                 |> Return.andThenVector (SingleArity func)
--                     (\items -> List.length items |> toFloat |> Number |> Expression)
--             )


callFunction : State -> (UndefinedReason -> List UndefinedTrackInfo) -> ( List String, Expression ) -> List Value -> LineResult
callFunction state trackStack ( paramNames, functionBody ) args =
    let
        closure =
            List.Extra.indexedFoldl
                (\index paramName state_ ->
                    let
                        trackStack_ =
                            trackStack (MissingPositionalArgument index paramName)
                    in
                    setVariable paramName (Return.argOrDefault trackStack_ index args) state_
                )
                state
                paramNames
    in
    -- TODO: closure should be only inScope
    runExpression closure functionBody


removeTracking : Expression -> UntrackedExp
removeTracking expr =
    case expr of
        Tracked _ e ->
            e

        Untracked e ->
            e


mapTracking : (UntrackedExp -> UntrackedExp) -> Expression -> Expression
mapTracking fn expr =
    case expr of
        Tracked info e ->
            Tracked info (fn e)

        Untracked e ->
            Untracked (fn e)



-- Debug.todo "call function"
-- eval state args
--     |> Return.andThenNum (SingleArity func)
--         (\param_ ->
--             eval (setVariable paramName param_ state) functionBody
--         )
-- callMapFunction : SingleArity -> State -> Expression -> ( String, String, Expression ) -> Return.Value
-- callMapFunction func state args ( functionParam, functionIndex, functionBody ) =
--     eval state args
--         |> Return.andThenVector (SingleArity func)
--             (\items ->
--                 List.Extra.indexedFoldl
--                     (\i _ acc ->
--                         let
--                             state_ =
--                                 state
--                                     |> setVector functionParam items
--                                     |> setVariable functionIndex (toFloat <| i + 1)
--                         in
--                         case ( acc, eval state_ functionBody ) of
--                             ( Expression (Vector items_), Expression e ) ->
--                                 Expression (Vector (items_ ++ [ e ]))
--                             ( Expression (Vector items_), error ) ->
--                                 error
--                             ( acc_, _ ) ->
--                                 acc_
--                     )
--                     (Expression (Vector []))
--                     items
--             )
-- runDoubleArity : State -> DoubleArity -> Expression -> Expression -> Return.Value
-- runDoubleArity state func e1 e2 =
--     let
--         numOp operator =
--             eval state e2
--                 |> Return.mapNum2 (DoubleArity func) operator (eval state e1)
--     in
--     case func of
--         Addition ->
--             numOp (+)
--         Subtraction ->
--             numOp (-)
--         Multiplication ->
--             numOp (*)
--         Division ->
--             numOp (/)
--         Exponentiation ->
--             numOp (^)
--         Frac ->
--             numOp (/)
--         Index ->
--             let
--                 vector =
--                     case e1 of
--                         Variable (ScalarIdentifier name) ->
--                             Variable (VectorIdentifier name)
--                         _ ->
--                             e1
--             in
--             eval state vector
--                 |> Return.andThenVector (\v -> DoubleArity Index v e2)
--                     (\items ->
--                         eval state e2
--                             |> Return.andThenNum
--                                 (DoubleArity Index (Vector items))
--                                 (\index ->
--                                     if not (isInteger index) || index < 1 then
--                                         throwError ("Cannot use " ++ String.fromFloat index ++ " as an index, it has to be a positive integer")
--                                     else
--                                         case List.head <| List.drop (round index - 1) items of
--                                             Just item ->
--                                                 Expression item
--                                             Nothing ->
--                                                 throwError ("Index " ++ String.fromFloat index ++ " out of bounds")
--                                 )
--                     )
--         Modulo ->
--             eval state e2
--                 |> Return.andThenNum2 (DoubleArity func)
--                     (\a b ->
--                         if isInteger a && isInteger b then
--                             Expression (Number (toFloat (round a |> modBy (round b))))
--                         else
--                             throwError ("Modulo operation can only be performed on integers, you are trying to calculate " ++ String.fromFloat a ++ " \\mod " ++ String.fromFloat b)
--                     )
--                     (eval state e1)
--         EuclideanDivision ->
--             eval state e2
--                 |> Return.andThenNum2 (DoubleArity func)
--                     (\a b ->
--                         if isInteger a && isInteger b then
--                             Expression (Number (toFloat <| floor <| a / b))
--                         else
--                             throwError ("Euclidean division can only be performed on integers, you are trying to calculate " ++ String.fromFloat a ++ " \\div " ++ String.fromFloat b)
--                     )
--                     (eval state e1)
-- isInteger : Float -> Bool
-- isInteger n =
--     n == toFloat (round n)
-- runTripleArity : State -> TripleArity -> Expression -> Expression -> Expression -> Return.Value
-- runTripleArity state func expr1 expr2 expr3 =
--     case func of
--         Sum_ identifier ->
--             let
--                 forLoop lowerLimit upperLimit =
--                     if not (isInteger lowerLimit) then
--                         throwError ("Error on sum_: cannot use " ++ String.fromFloat lowerLimit ++ " as a lower limit, it has to be an integer")
--                     else if not (isInteger upperLimit) || upperLimit < lowerLimit then
--                         throwError ("Error on sum_: cannot use " ++ String.fromFloat upperLimit ++ " as an upper limit, it has to be an integer higher than lower limit")
--                     else
--                         List.range (round lowerLimit) (round upperLimit)
--                             |> List.foldl iterate (Expression (Number 0))
--                 iterate curr total =
--                     let
--                         state_ =
--                             setVariable identifier (toFloat curr) state
--                     in
--                     eval state_ expr3
--                         |> Return.mapNum2 (\_ -> TripleArity func expr1 expr2) (\result total_ -> total_ + result) total
--             in
--             Return.andThenNum2 (\e1 e2 -> TripleArity func e1 e2 expr3)
--                 forLoop
--                 (eval state expr1)
--                 (eval state expr2)


eval : State -> Expression -> Value
eval state =
    runExpression state >> .result


setVariable : String -> Value -> State -> State
setVariable name value state =
    { state | variables = Dict.insert name value state.variables }
