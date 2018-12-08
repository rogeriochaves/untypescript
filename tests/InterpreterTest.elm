module InterpreterTest exposing (suite)

import Expect exposing (Expectation)
import Interpreter exposing (..)
import MathParser exposing (..)
import Parser exposing (Problem(..))
import Return
import Test exposing (..)


suite : Test
suite =
    describe "Interpreter suite"
        [ describe "parsing and executing"
            [ test "sum integer numbers" <|
                \_ ->
                    MathParser.parse "1 + 1"
                        |> Result.andThen Interpreter.run
                        |> Expect.equal (Ok [ Return.Num 2 ])
            , test "sum float numbers" <|
                \_ ->
                    MathParser.parse "1.5 + 1.3"
                        |> Result.andThen Interpreter.run
                        |> Expect.equal (Ok [ Return.Num 2.8 ])
            , test "execute nested expressions" <|
                \_ ->
                    MathParser.parse "1 - (3 - 2)"
                        |> Result.andThen Interpreter.run
                        |> Expect.equal (Ok [ Return.Num 0 ])
            , test "respects math priority" <|
                \_ ->
                    MathParser.parse "2 + 3 * 2"
                        |> Result.andThen Interpreter.run
                        |> Expect.equal (Ok [ Return.Num 8 ])
            , test "respects math priority #2" <|
                \_ ->
                    MathParser.parse "2 * 3 + 2"
                        |> Result.andThen Interpreter.run
                        |> Expect.equal (Ok [ Return.Num 8 ])
            , test "symbol function aplication with other expression" <|
                \_ ->
                    MathParser.parse "\\sqrt{9} + 2"
                        |> Result.andThen Interpreter.run
                        |> Expect.equal (Ok [ Return.Num 5 ])
            , test "symbol function aplication on a expression" <|
                \_ ->
                    MathParser.parse "\\sqrt{7 + 2}"
                        |> Result.andThen Interpreter.run
                        |> Expect.equal (Ok [ Return.Num 3 ])
            , test "exponentiation" <|
                \_ ->
                    MathParser.parse "2 ^ 5"
                        |> Result.andThen Interpreter.run
                        |> Expect.equal (Ok [ Return.Num 32 ])
            , test "respects math priority #3" <|
                \_ ->
                    MathParser.parse "2 * 3 ^ 5"
                        |> Result.andThen Interpreter.run
                        |> Expect.equal (Ok [ Return.Num 486 ])
            ]
        , describe "symbols"
            [ test "sqrt" <|
                \_ ->
                    MathParser.parse "\\sqrt{9}"
                        |> Result.andThen Interpreter.run
                        |> Expect.equal (Ok [ Return.Num 3 ])
            , test "frac" <|
                \_ ->
                    MathParser.parse "\\frac{3}{2}"
                        |> Result.andThen Interpreter.run
                        |> Expect.equal (Ok [ Return.Num 1.5 ])
            , test "summation" <|
                \_ ->
                    MathParser.parse "\\sum_{x=1}^{3} 5"
                        |> Result.andThen Interpreter.run
                        |> Expect.equal (Ok [ Return.Num 15 ])
            , test "summation using the variable" <|
                \_ ->
                    MathParser.parse "\\sum_{x=1}^{3} x + 1"
                        |> Result.andThen Interpreter.run
                        |> Expect.equal (Ok [ Return.Num 9 ])
            , test "summation with a float upper limit should break" <|
                \_ ->
                    MathParser.parse "\\sum_{x=1}^{3.9} 5"
                        |> Result.andThen Interpreter.run
                        |> Expect.equal
                            (Err
                                [ { row = 0
                                  , col = 0
                                  , problem = Problem "Error on sum_: cannot use 3.9 as an upper limit, it has to be an integer higher than lower limit"
                                  }
                                ]
                            )
            , test "summation with a float lower limit should break" <|
                \_ ->
                    MathParser.parse "\\sum_{x=1.9}^{3} 5"
                        |> Result.andThen Interpreter.run
                        |> Expect.equal
                            (Err
                                [ { row = 0
                                  , col = 0
                                  , problem = Problem "Error on sum_: cannot use 1.9 as a lower limit, it has to be an integer"
                                  }
                                ]
                            )
            , test "summation with a upper limit lower than lower limit" <|
                \_ ->
                    MathParser.parse "\\sum_{x=1}^{0-5} 5"
                        |> Result.andThen Interpreter.run
                        |> Expect.equal
                            (Err
                                [ { row = 0
                                  , col = 0
                                  , problem = Problem "Error on sum_: cannot use -5 as an upper limit, it has to be an integer higher than lower limit"
                                  }
                                ]
                            )
            ]
        , test "multiple expressions" <|
            \_ ->
                MathParser.parse "1 + 1\n2 + 2"
                    |> Result.andThen Interpreter.run
                    |> Expect.equal (Ok [ Return.Num 2, Return.Num 4 ])
        , describe "assignments" <|
            [ test "parses a simple assignment and return void" <|
                \_ ->
                    MathParser.parse "x = 2 + 2"
                        |> Result.andThen Interpreter.run
                        |> Expect.equal (Ok [ Return.Void ])
            , test "saves the value to the variable" <|
                \_ ->
                    MathParser.parse "x = 2 + 2\nx + 1"
                        |> Result.andThen Interpreter.run
                        |> Expect.equal (Ok [ Return.Void, Return.Num 5 ])
            , test "return errors from undefined variables" <|
                \_ ->
                    MathParser.parse "y"
                        |> Result.andThen Interpreter.run
                        |> Expect.equal
                            (Err
                                [ { row = 0
                                  , col = 0
                                  , problem = Problem "y is not defined"
                                  }
                                ]
                            )
            ]
        , describe "functions"
            [ test "declares a simple function" <|
                \_ ->
                    MathParser.parse "f(x) = x + 1\nf(5)"
                        |> Result.andThen Interpreter.run
                        |> Expect.equal (Ok [ Return.Void, Return.Num 6 ])
            , test "return errors from undefined functions" <|
                \_ ->
                    MathParser.parse "f(x)"
                        |> Result.andThen Interpreter.run
                        |> Expect.equal
                            (Err
                                [ { row = 0
                                  , col = 0
                                  , problem = Problem "f is not defined"
                                  }
                                ]
                            )
            ]
        ]
