module AstParser exposing (parse)

import Dict
import Parser exposing (..)
import Parser.Expression exposing (..)
import Parser.Extras exposing (..)
import Set
import Types exposing (..)


digits : Parser Expression
digits =
    number
        { int = Just (toFloat >> Number >> Value >> Untracked)
        , hex = Nothing
        , octal = Nothing
        , binary = Nothing
        , float = Just (Number >> Value >> Untracked)
        }


identifier : Parser String
identifier =
    scalarIdentifier


vectorIdentifier : Parser String
vectorIdentifier =
    succeed identity
        |. oneOf [ symbol "\\vec", symbol "\\mathbf" ]
        |= braces scalarIdentifier


scalarIdentifier : Parser String
scalarIdentifier =
    let
        decorators =
            succeed ()
                |. oneOf [ symbol "\\tilde", symbol "\\bar" ]
                |. braces names

        names =
            oneOf
                (lowercaseGreek
                    ++ [ succeed ()
                            |. chompIf (\c -> Char.isLower c && Char.isAlphaNum c)
                       , succeed ()
                            |. symbol "\\operatorname"
                            |. braces
                                (variable
                                    { start = Char.isAlphaNum
                                    , inner = \c -> Char.isAlphaNum c
                                    , reserved = Set.empty
                                    }
                                )
                       ]
                )
    in
    oneOf
        [ decorators
        , names
        ]
        |> getChompedString


lowercaseGreek : List (Parser ())
lowercaseGreek =
    List.map symbol
        [ "\\alpha"
        , "\\beta"
        , "\\gamma"
        , "\\delta"
        , "\\epsilon"
        , "\\varepsilon"
        , "\\zeta"
        , "\\eta"
        , "\\theta"
        , "\\vartheta"
        , "\\iota"
        , "\\kappa"
        , "\\lambda"
        , "\\mu"
        , "\\nu"
        , "\\xi"
        , "\\pi"
        , "\\rho"
        , "\\sigma"
        , "\\tau"
        , "\\upsilon"
        , "\\phi"
        , "\\chi"
        , "\\psi"
        , "\\omega"
        ]


symbolIdentifier : Parser String
symbolIdentifier =
    variable
        { start = Char.isLower
        , inner = \c -> Char.isAlphaNum c || c == '_'
        , reserved = Set.fromList []
        }


tracked : ( Int, Int ) -> UntrackedExp -> Expression
tracked ( row, col ) =
    Tracked { line = row, column = col }


functionCall : Parser Expression
functionCall =
    -- TODO: separate application of variables from reserved
    succeed (\pos name -> tracked pos << Application (Untracked (Variable name)))
        |= getPosition
        |= backtrackable scalarIdentifier
        |= backtrackable
            (sequence
                { start = "("
                , separator = ","
                , end = ")"
                , spaces = spaces
                , item = expression
                , trailing = Forbidden
                }
            )


infixOperator : Reserved -> Parser ( Int, Int ) -> Assoc -> Operator Expression
infixOperator operation opParser assoc =
    let
        binaryOp =
            succeed (\pos expr1 expr2 -> tracked pos (doubleArity operation expr1 expr2))
                |= getPosition
                |. opParser
                |. spaces
    in
    Infix binaryOp assoc


operators : OperatorTable Expression
operators =
    let
        symb : String -> Parser ( Int, Int )
        symb sign =
            succeed identity
                |. backtrackable spaces
                |= getPosition
                |. symbol sign
    in
    -- [ [ prefixOperator (SingleArity Negation) (symbol "-") ]
    -- , [ infixOperator Exponentiation (symb "^") AssocLeft ]
    -- , [ infixOperator Multiplication (symb "*") AssocLeft, infixOperator Division (symb "/") AssocLeft ]
    -- , [ infixOperator Modulo (symb "\\mod") AssocLeft, infixOperator EuclideanDivision (symb "\\div") AssocLeft ]
    [ [ infixOperator Addition (symb "+") AssocLeft, infixOperator Subtraction (symb "-") AssocLeft ]
    ]


assignment : Parser Expression
assignment =
    succeed (\pos name -> tracked pos << singleArity (Assignment name))
        |= getPosition
        |= backtrackable identifier
        |. backtrackable spaces
        |. symbol "="
        |. spaces
        |= expression


functionDeclaration : Parser Expression
functionDeclaration =
    succeed
        (\name param body ->
            Untracked
                (Application
                    (Untracked (Reserved (Assignment name)))
                    [ Untracked (Value (Abstraction param body)) ]
                )
        )
        |= backtrackable identifier
        |. backtrackable spaces
        |. backtrackable (symbol "=")
        |. backtrackable spaces
        |= backtrackable
            (sequence
                { start = "("
                , separator = ","
                , end = ")"
                , spaces = spaces
                , item = identifier
                , trailing = Forbidden
                }
            )
        |. backtrackable spaces
        |. backtrackable (symbol "=>")
        |. spaces
        |= expression


singleArity : Reserved -> Expression -> UntrackedExp
singleArity fn expr =
    Application (Untracked (Reserved fn)) [ expr ]


doubleArity : Reserved -> Expression -> Expression -> UntrackedExp
doubleArity fn expr1 expr2 =
    Application (Untracked (Reserved fn)) [ expr1, expr2 ]



-- mapFunctionDeclaration : Parser Expression
-- mapFunctionDeclaration =
--     succeed (\name param idx body -> SingleArity (Assignment (ScalarIdentifier name)) (MapAbstraction param idx body))
--         |= backtrackable scalarIdentifier
--         |= backtrackable (parens vectorIdentifier)
--         |. backtrackable (symbol "_")
--         |= braces scalarIdentifier
--         |. spaces
--         |. symbol "="
--         |. spaces
--         |= expression
-- index : Expression -> Parser Expression
-- index expr =
--     succeed (DoubleArity Index expr)
--         |. backtrackable (symbol "_")
--         |= backtrackable (braces (lazy <| \_ -> expression))
-- exponentiation : Expression -> Parser Expression
-- exponentiation expr =
--     succeed (DoubleArity Exponentiation expr)
--         |. backtrackable spaces
--         |. backtrackable (symbol "^")
--         |. backtrackable spaces
--         |= backtrackable (braces (lazy <| \_ -> expression))
-- factorial : Expression -> Parser Expression
-- factorial expr =
--     succeed (SingleArity Factorial expr)
--         |. backtrackable (symbol "!")


program : Parser Types.Program
program =
    loop [] programLoop


programLoop : List Expression -> Parser (Step (List Expression) (List Expression))
programLoop expressions =
    let
        appendExpr expr =
            case List.head expressions of
                Just (Tracked _ (Block name items)) ->
                    Loop (Untracked (Block name (items ++ [ expr ])) :: List.drop 1 expressions)

                _ ->
                    Loop (expr :: expressions)

        statementBreak =
            succeed ()
                |. chompWhile (\c -> c == ' ')
                |. chompIf (\c -> c == '\n')
                |. spaces
    in
    oneOf
        [ succeed (Done (List.reverse expressions))
            |. symbol "EOF"
        , succeed (\name -> Loop (Untracked (Block name []) :: expressions))
            |= backtrackable (getChompedString (chompWhile (\c -> c /= ':' && c /= '\n')))
            |. symbol ":"
            |. statementBreak
        , succeed appendExpr
            |= expression_ True
            |. statementBreak
        ]


expression : Parser Expression
expression =
    expression_ False


expression_ : Bool -> Parser Expression
expression_ withDeclarations =
    buildExpressionParser operators
        (lazy <|
            \_ ->
                expressionParsers withDeclarations
                    |> andThen
                        (\expr ->
                            oneOf
                                [ -- index expr
                                  -- , exponentiation expr
                                  -- , factorial expr
                                  succeed expr
                                ]
                        )
        )


expressionParsers : Bool -> Parser Expression
expressionParsers withDeclarations =
    let
        declarations =
            [ functionDeclaration
            , assignment
            ]

        -- [ mapFunctionDeclaration
        -- , functionDeclaration
        -- , assignment
        -- ]
        expressions =
            [ backtrackable <| parens <| lazy (\_ -> expression)
            , functionCall
            , atoms
            , vectors
            ]
    in
    if withDeclarations then
        oneOf (declarations ++ expressions)

    else
        oneOf expressions


atoms : Parser Expression
atoms =
    oneOf
        [ succeed (\pos name -> tracked pos (Variable name))
            |= getPosition
            |= identifier
        , digits
        ]


vectors : Parser Expression
vectors =
    succeed (Vector >> Value >> Untracked)
        |= sequence
            { start = "("
            , separator = ","
            , end = ")"
            , spaces = spaces
            , item = expression
            , trailing = Forbidden
            }


parse : String -> Result Error Types.Program
parse string =
    run program (string ++ "\nEOF")