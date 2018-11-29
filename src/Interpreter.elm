module Interpreter exposing (run, runSymbol)

import Dict exposing (Dict)
import Types exposing (..)


type alias State =
    { variables : Dict String Float
    }


newState : State
newState =
    { variables = Dict.empty
    }


type alias Result =
    ( State, Float )


run : Types.Program -> List Float
run expressions =
    let
        iterate : Expression -> List Result -> List Result
        iterate expr accummulated =
            let
                lastResult =
                    List.head accummulated
                        |> Maybe.withDefault ( newState, 0 )

                result =
                    runExpression (Tuple.first lastResult) expr
            in
            result :: accummulated
    in
    expressions
        |> List.foldl iterate []
        |> List.reverse
        |> List.map Tuple.second


getExpressionValue : State -> Expression -> Float
getExpressionValue state =
    runExpression state >> Tuple.second


runExpression : State -> Expression -> Result
runExpression state expr =
    case expr of
        Integer val ->
            ( state, toFloat val )

        Floating val ->
            ( state, val )

        Identifier name ->
            -- TODO: break if variable is not available
            ( state, Dict.get name state.variables |> Maybe.withDefault 0 )

        Addition e1 e2 ->
            ( state, getExpressionValue state e1 + getExpressionValue state e2 )

        Subtraction e1 e2 ->
            ( state, getExpressionValue state e1 - getExpressionValue state e2 )

        Multiplication e1 e2 ->
            ( state, getExpressionValue state e1 * getExpressionValue state e2 )

        Division e1 e2 ->
            ( state, getExpressionValue state e1 / getExpressionValue state e2 )

        Exponentiation e1 e2 ->
            ( state, getExpressionValue state e1 ^ getExpressionValue state e2 )

        SymbolicFunction symbol ->
            ( state, runSymbol state symbol )

        Equation identifier e ->
            let
                result =
                    getExpressionValue state e
            in
            case identifier of
                Identifier name ->
                    ( { state | variables = Dict.insert name result state.variables }, result )

                _ ->
                    -- TODO: break here
                    ( state, result )


runSymbol : State -> Symbol -> Float
runSymbol state symbol =
    case symbol of
        SingleArity sym expr1 ->
            case sym of
                Sqrt ->
                    sqrt (getExpressionValue state expr1)

        DoubleArity sym expr1 expr2 ->
            case sym of
                Frac ->
                    getExpressionValue state expr1 / getExpressionValue state expr2

        Iterator sym expr1 expr2 expr3 ->
            case sym of
                Sum_ ->
                    let
                        lowerLimit =
                            getExpressionValue state expr1

                        upperLimit =
                            getExpressionValue state expr2

                        range =
                            -- TODO: remove round, make sure expression is int
                            List.range (round lowerLimit) (round upperLimit)
                    in
                    List.foldl (\curr total -> total + getExpressionValue state expr3) 0 range
