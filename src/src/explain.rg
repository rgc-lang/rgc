# RGC compiler: `rgc explain E0XXX` error-code documentation database.
#
# This module maps every stable error code to a human-readable explanation in
# the style of `rustc --explain E0XXX`. It is data-only (no dependency on the
# rest of the compiler), so it can be embedded in the CLI, the LSP, or future
# documentation generators.
#
# The authoritative table lives in devdoc/RGC-0.0.5-ERRORCODES.md; keep the two
# in sync when adding or renumbering codes.

# Return the explanation text for an error code, or "" when the code is unknown.
public def explain_for_code(code: str) -> str {
    db = make_explain_db()
    if db.contains(code) {
        return db.get(code)
    }
    return ""
}

# Build the code -> explanation map.
def make_explain_db() -> Map[str, str] {
    db = Map[str, str]()

    # ---- E00xx CLI / driver / file I/O ----
    db.put("E0001",
           "The compiler could not read the specified source file.\n\n" +
           "Check that the path is correct, the file exists, and the current\n" +
           "user has read permission for it.")
    db.put("E0002",
           "The compiler could not write the output file.\n\n" +
           "Check that the output directory exists and is writable, and that\n" +
           "there is enough free disk space.")
    db.put("E0003",
           "The compiler could not read a module file.\n\n" +
           "The module path was resolved but the file could not be opened.\n" +
           "Check that the module file exists and is readable.")
    db.put("E0004",
           "The LLVM backend failed to generate an object file from the\n" +
           "compiler's intermediate representation.\n\n" +
           "This usually indicates an internal compiler bug. Minimize the\n" +
           "reproducing program and report it with the full diagnostic output.")
    db.put("E0005",
           "The system linker (g++) failed while linking the generated object\n" +
           "file into an executable.\n\n" +
           "This is usually an environment issue: a missing library, an\n" +
           "unresolved symbol, or a broken toolchain installation.")
    db.put("E0006",
           "The command line does not name a valid compiler command, or the\n" +
           "arguments are wrong.\n\n" +
           "Run `rgc` without arguments to see the supported usage.")

    # ---- E01xx lexical ----
    db.put("E0101",
           "A block comment opened with `/*` was never closed with `*/`.\n\n" +
           "Add the missing `*/` at the end of the comment.")
    db.put("E0102",
           "A string literal was not closed before the end of the line.\n\n" +
           "Add a closing `\"`. If the string contains a `\"` character, escape\n" +
           "it with `\\\"` instead of ending the literal early.")

    # ---- E02xx syntax ----
    db.put("E0201",
           "The parser expected a particular token (such as `(`, `{`, or `:`)\n" +
           "but found something else at that position.\n\n" +
           "Look at the highlighted token and add the missing syntax that the\n" +
           "parser expected.")
    db.put("E0202",
           "The parser found a token that is not allowed at this position.\n\n" +
           "Remove the unexpected token or move it to the correct place.")
    db.put("E0203",
           "A declaration or parameter is missing its type annotation.\n\n" +
           "RGC requires explicit types in declarations and parameter lists;\n" +
           "add one (for example `x: int`).")
    db.put("E0204",
           "The left-hand side of an assignment is not a valid assignment\n" +
           "target.\n\n" +
           "Only variables and member paths (such as `p.x`) can be assigned\n" +
           "to; literals and arbitrary expressions cannot.")
    db.put("E0205",
           "The pattern in a `match` case is malformed.\n\n" +
           "Patterns can be a variant constructor with arguments, an enum\n" +
           "variant name, a variable binding, or `_`.")
    db.put("E0206",
           "`public` must be followed by a top-level declaration: `def`,\n" +
           "`class`, `enum`, or `interface`.\n\n" +
           "Place `public` immediately before one of those keywords.")
    db.put("E0207",
           "An `interface` body must contain method declarations.\n\n" +
           "Declare the methods of the interface inside its braces, each with\n" +
           "a signature and a `;` or a body.")
    db.put("E0208",
           "A function parameter is missing its `: type` annotation.\n\n" +
           "Write the parameter as `name: type`, for example `x: int`.")
    db.put("E0209",
           "A `match` body must contain `case` arms.\n\n" +
           "Write at least one `case <pattern> => <expression>` arm inside the\n" +
           "match braces.")

    # ---- E03xx module / name resolution / visibility ----
    db.put("E0301",
           "The module file could not be read at the resolved path.\n\n" +
           "Check that the module file exists, the path is correct, and the\n" +
           "file is readable.")
    db.put("E0302",
           "Two modules export the same binding, so the name is ambiguous in\n" +
           "the current module.\n\n" +
           "Qualify the name with the module prefix, or rename one of the\n" +
           "exported symbols.")
    db.put("E0303",
           "A private type cannot be re-exported from a module.\n\n" +
           "Make the type public in its defining module, or stop re-exporting\n" +
           "it.")
    db.put("E0304",
           "The re-export names a symbol that does not exist or is not public\n" +
           "in the target module.\n\n" +
           "Check the spelling and the visibility of the symbol.")
    db.put("E0305",
           "A symbol marked `public` in another module is private to that\n" +
           "module and cannot be used here.\n\n" +
           "Only `public` symbols are visible outside their defining module.")
    db.put("E0306",
           "A function name is exported by several modules and the compiler\n" +
           "cannot decide which one you mean.\n\n" +
           "Qualify the call with the module prefix, e.g. `mymod.f()`.")
    db.put("E0307",
           "A type name is defined in several modules and the compiler cannot\n" +
           "decide which one you mean.\n\n" +
           "Qualify the type with the module prefix.")
    db.put("E0308",
           "The named module does not export a public function with that\n" +
           "name.\n\n" +
           "Check the function name and that it is marked `public` in the\n" +
           "module.")

    # ---- E04xx type checking ----
    db.put("E0401",
           "A value has a different type than the one expected at this\n" +
           "position (declaration, assignment, function argument, etc.).\n\n" +
           "This is the RGC equivalent of rustc's E0308. Change the value to\n" +
           "the expected type, or change the expected type to match the value.")
    db.put("E0402",
           "A type name is defined more than once in the same scope.\n\n" +
           "Use a different name for one of the definitions.")
    db.put("E0403",
           "An `interface` is declared more than once.\n\n" +
           "Merge the declarations or rename one of them.")
    db.put("E0404",
           "The two branches of an `if` expression produce values of\n" +
           "different types.\n\n" +
           "Make both branches return the same type (or make both return\n" +
           "`None`).")
    db.put("E0405",
           "The value returned by a function does not match its declared\n" +
           "return type.\n\n" +
           "Change the return type annotation, or make the returned expression\n" +
           "have the expected type.")
    db.put("E0406",
           "The `+` operator on strings only concatenates two strings.\n\n" +
           "Convert the other operand to a string first (for example with\n" +
           "`to_string`) before concatenating.")
    db.put("E0407",
           "Member access with `.` is only allowed on class values.\n\n" +
           "This value is not a class instance, so it has no fields.")
    db.put("E0408",
           "Member access with `.` is not allowed on enum values.\n\n" +
           "Extract data from an enum with a `match` on its variants instead.")
    db.put("E0409",
           "The class does not have a field with this name.\n\n" +
           "Check the spelling of the field, or add the field to the class\n" +
           "definition.")

    # ---- E05xx expression name resolution ----
    db.put("E0501",
           "The variable is not declared in the current scope.\n\n" +
           "Declare it before use, or check the spelling. A `help:` line\n" +
           "suggests a similarly named variable when one exists.")
    db.put("E0502",
           "No function with this name is in scope.\n\n" +
           "Define the function, import it from a module, or check the\n" +
           "spelling. A `help:` line suggests a similarly named function when\n" +
           "one exists.")

    # ---- E06xx ownership / move ----
    db.put("E0601",
           "The value was already moved, so it cannot be used again.\n\n" +
           "In RGC, values of custom types (classes, enums, List, Map, Task,\n" +
           "...) are moved when assigned or passed by value. Use the value\n" +
           "only once, reorder the operations, or borrow it with `@x` / `@var x`\n" +
           "instead of moving it.")
    db.put("E0602",
           "A value cannot be moved out of an active borrow.\n\n" +
           "The value is currently borrowed, so moving it would leave the\n" +
           "borrow pointing at invalid data. Restructure the code to avoid the\n" +
           "move while the borrow is live.")

    # ---- E07xx borrow checking ----
    db.put("E0701",
           "Two borrows of the same variable conflict.\n\n" +
           "A variable can be borrowed either by any number of shared borrows\n" +
           "(`@x`) OR by a single mutable borrow (`@var x`), but not both at\n" +
           "the same time. Restructure the code so the conflicting borrows do\n" +
           "not overlap.")
    db.put("E0702",
           "The variable is currently mutably borrowed (`@var`), so it cannot\n" +
           "be read or used directly.\n\n" +
           "While a `@var` borrow is live, access to the variable goes through\n" +
           "the borrow handle exclusively. Read through the handle instead.")
    db.put("E0703",
           "A shared borrow (`@x`) only allows reading, so it cannot be\n" +
           "assigned through.\n\n" +
           "Take a mutable borrow (`@var x`) if the value must be written.")
    db.put("E0704",
           "The `@` / `@var` borrow operators can only borrow a named\n" +
           "variable.\n\n" +
           "Borrow a variable directly; arbitrary expressions cannot be\n" +
           "borrowed.")
    db.put("E0705",
           "A borrow handle cannot be copied.\n\n" +
           "Borrow handles are unique handles into the value. Create a new\n" +
           "borrow with `@` or `@var` instead of copying the handle.")

    # ---- E08xx generics / interfaces ----
    db.put("E0801",
           "A type parameter is inferred to have different types at different\n" +
           "call sites.\n\n" +
           "Make the call sites agree, or annotate the type parameter\n" +
           "explicitly.")
    db.put("E0802",
           "The compiler cannot infer a type parameter for a generic function\n" +
           "call.\n\n" +
           "Annotate the type argument explicitly at the call site.")
    db.put("E0803",
           "A type used as a generic argument does not implement the required\n" +
           "interface.\n\n" +
           "Implement the interface for the type, or use a type that satisfies\n" +
           "the bound.")
    db.put("E0804",
           "A class claims to implement an interface but is missing one of its\n" +
           "methods.\n\n" +
           "Add the missing method with the exact signature declared in the\n" +
           "interface.")
    db.put("E0805",
           "A method's signature does not match the interface declaration.\n\n" +
           "Adjust the method's parameter types or return type to match the\n" +
           "interface.")
    db.put("E0806",
           "No interface with this name is in scope.\n\n" +
           "Define the interface, import it, or check the spelling.")
    db.put("E0807",
           "Type arguments were given to a class that is not generic.\n\n" +
           "Remove the type arguments, or make the class generic.")
    db.put("E0808",
           "A generic class received the wrong number of type arguments.\n\n" +
           "Provide exactly as many type arguments as the class declares.")
    db.put("E0809",
           "Type arguments were given to an enum that is not generic.\n\n" +
           "Remove the type arguments, or make the enum generic.")
    db.put("E0810",
           "A generic enum received the wrong number of type arguments.\n\n" +
           "Provide exactly as many type arguments as the enum declares.")

    # ---- E09xx function / call / arguments ----
    db.put("E0901",
           "A function call provides a different number of arguments than the\n" +
           "function accepts.\n\n" +
           "Add or remove arguments so the call matches the function's\n" +
           "parameter list.")
    db.put("E0902",
           "An argument's type does not match the declared parameter type.\n\n" +
           "Convert the argument to the expected type, or change the parameter\n" +
           "type.")
    db.put("E0903",
           "A builtin or method received the wrong number of arguments.\n\n" +
           "Check the builtin's documented signature and pass the expected\n" +
           "number of arguments.")
    db.put("E0904",
           "A builtin expected a numeric argument but found a value of another\n" +
           "type.\n\n" +
           "Pass an `int` or `float` to the builtin.")
    db.put("E0905",
           "A builtin argument has a different type than expected.\n\n" +
           "Convert the argument to the expected type before the call.")

    # ---- E10xx enum / match / patterns ----
    db.put("E1001",
           "The enum does not have a variant with this name.\n\n" +
           "Check the spelling of the variant, or add the variant to the enum\n" +
           "definition.")
    db.put("E1002",
           "An argument passed to an enum variant constructor has a different\n" +
           "type than the variant declares.\n\n" +
           "Convert the argument to the expected type, or change the variant's\n" +
           "field type.")
    db.put("E1003",
           "The arms of a `match` produce values of different types.\n\n" +
           "Make every `case` arm return the same type (or make every arm\n" +
           "return `None`).")

    # ---- E11xx control flow ----
    db.put("E1101",
           "`break` can only be used inside a `for` or `while` loop.\n\n" +
           "Move the `break` into a loop body, or remove it.")
    db.put("E1102",
           "`continue` can only be used inside a `for` or `while` loop.\n\n" +
           "Move the `continue` into a loop body, or remove it.")

    # ---- E12xx async / Task ----
    db.put("E1201",
           "An `extern` (FFI) function cannot be declared async.\n\n" +
           "Remove `async` from the extern declaration and expose a synchronous\n" +
           "wrapper instead.")
    db.put("E1202",
           "Methods cannot be declared async.\n\n" +
           "Use a top-level async function or a Task-returning helper instead.")
    db.put("E1203",
           "The `main` entry point cannot be async.\n\n" +
           "Make `main` synchronous and drive the async task with\n" +
           "`asyncio.run(task)` inside it.")
    db.put("E1204",
           "An async function cannot return a borrow.\n\n" +
           "A borrow cannot live across an `await` boundary. Return an owned\n" +
           "value instead.")
    db.put("E1205",
           "An async function cannot take a borrow parameter.\n\n" +
           "A borrow cannot live across an `await` boundary. Take an owned\n" +
           "value instead.")
    db.put("E1206",
           "`await` is only allowed inside an async function.\n\n" +
           "Move the `await` into an `async def`, or remove it.")
    db.put("E1207",
           "`await` expects a `Task` value.\n\n" +
           "Tasks are created by calling an async function. Await only Task\n" +
           "values.")
    db.put("E1208",
           "`asyncio.run()` expects exactly 1 argument.\n\n" +
           "Pass the task to run, for example `asyncio.run(my_task())`.")
    db.put("E1209",
           "`asyncio.run()` expects a Task value.\n\n" +
           "Pass a Task returned by an async function call.")
    db.put("E1210",
           "`asyncio.cancelled()` takes no arguments.\n\n" +
           "Call it without arguments.")
    db.put("E1211",
           "A Task that is currently borrowed cannot be awaited.\n\n" +
           "Awaiting consumes the Task. Do not hold a borrow across the await.")
    db.put("E1212",
           "A task list that is currently borrowed cannot be gathered.\n\n" +
           "`asyncio.gather` consumes the list. Do not hold a borrow across the\n" +
           "gather.")
    db.put("E1213",
           "`asyncio.gather()` expects exactly 1 argument: a `List[Task]`.\n\n" +
           "Pass a list of tasks to gather.")
    db.put("E1214",
           "`asyncio.gather()` expects `List[Task[T]]` but found another type.\n\n" +
           "Build a list of Task values and pass it.")
    db.put("E1215",
           "`asyncio.gather()` does not yet support tasks without a value.\n\n" +
           "Give the tasks a value type, or use a different joining API.")
    db.put("E1216",
           "`asyncio.wait_any()` expects exactly 1 argument: a `List[Task]`.\n\n" +
           "Pass a list of tasks.")
    db.put("E1217",
           "`asyncio.wait_any()` expects `List[Task[T]]` but found another type.\n\n" +
           "Build a list of Task values and pass it.")
    db.put("E1218",
           "Task values can only be created by calling an async function.\n\n" +
           "Call an async function to obtain a Task; you cannot construct one\n" +
           "directly.")
    db.put("E1219",
           "`Task.wait()` expects exactly 1 argument: a millisecond count.\n\n" +
           "Pass an `int` number of milliseconds to wait.")
    db.put("E1220",
           "`Task.wait()` expects an `int` millisecond count.\n\n" +
           "Convert the argument to `int`.")
    db.put("E1221",
           "This Task method takes no arguments.\n\n" +
           "Call it without arguments.")

    # ---- E13xx format strings ----
    db.put("E1301",
           "`format()` expects at least 1 argument: the format string.\n\n" +
           "Pass a format string literal as the first argument.")
    db.put("E1302",
           "`format()` expects a string literal as its first argument.\n\n" +
           "The format template must be a literal so the compiler can validate\n" +
           "its placeholders.")
    db.put("E1303",
           "The format string contains `{` without a matching `}`.\n\n" +
           "Close every placeholder with `}`.")
    db.put("E1304",
           "The format string contains `}` without a matching `{`.\n\n" +
           "Remove the stray `}` or add the opening `{`.")
    db.put("E1305",
           "The number of placeholder arguments does not match the number of\n" +
           "`{}` placeholders in the format string.\n\n" +
           "Provide exactly one argument per placeholder.")
    db.put("E1306",
           "`format()` arguments must be `int`, `float`, `bool`, or `str`.\n\n" +
           "Convert unsupported values to a string with `to_string` first.")
    db.put("E1307",
           "The format specifier after `:` is invalid.\n\n" +
           "Use a supported format specifier (see the format documentation).")

    # ---- E14xx FFI / extern ----
    db.put("E1401",
           "An `extern` function cannot be generic.\n\n" +
           "Remove the type parameters from the extern declaration.")
    db.put("E1402",
           "An `extern` function's return type must be a primitive:\n" +
           "`int`, `float`, `bool`, `str`, or `None`.\n\n" +
           "Change the return type to a primitive.")
    db.put("E1403",
           "An `extern` function's parameters must be primitive types:\n" +
           "`int`, `float`, `bool`, or `str`.\n\n" +
           "Change the parameter types to primitives.")

    # ---- E15xx builtins / standard library methods ----
    db.put("E1501",
           "This List method is not yet supported for custom element types.\n\n" +
           "Use a supported element type, or implement the operation manually\n" +
           "for custom types.")
    db.put("E1502",
           "`to_string()` expects exactly 1 argument.\n\n" +
           "Pass the value to convert.")
    db.put("E1503",
           "`to_string()` only supports `int`, `float`, and `bool`.\n\n" +
           "Convert unsupported values some other way.")
    db.put("E1504",
           "`chr()` expects exactly 1 argument.\n\n" +
           "Pass the integer code point to convert.")
    db.put("E1505",
           "`chr()` expects an `int` argument.\n\n" +
           "Convert the argument to `int`.")
    db.put("E1506",
           "`args()` takes no arguments.\n\n" +
           "Call it without arguments.")
    db.put("E1507",
           "`range()` can only be used as a `for`-loop iterable.\n\n" +
           "Use `range` in a `for i in range(...)` loop, not as a standalone\n" +
           "value.")
    db.put("E1508",
           "`range()` expects 1 to 3 arguments: `range(stop)`,\n" +
           "`range(start, stop)`, or `range(start, stop, step)`.\n\n" +
           "Pass the correct number of arguments.")
    db.put("E1509",
           "`range()` expects `int` arguments.\n\n" +
           "Convert the arguments to `int`.")

    # ---- E16xx `?` operator / Result ----
    db.put("E1601",
           "The `?` operator requires a `Result` value.\n\n" +
           "`?` unwraps a `Result`: on `Err` it returns the error from the\n" +
           "current function, on `Ok` it yields the success value. It only\n" +
           "works on `Result` values.")
    db.put("E1602",
           "The `?` operator can only be used in a function whose return type\n" +
           "is `Result`.\n\n" +
           "Change the function's return type to `Result`, or handle the error\n" +
           "with a `match` instead of `?`.")
    db.put("E1603",
           "The error type of the `Result` value does not match the error type\n" +
           "of the enclosing function's `Result`.\n\n" +
           "Convert the error to the expected type before using `?`.")
    db.put("E1604",
           "The `?` operator does not yet support custom success payloads.\n\n" +
           "Use a `match` to extract the payload manually.")

    # ---- fallback ----
    db.put("E0000",
           "This diagnostic did not receive a classified error code.\n\n" +
           "It is an internal fallback. Please report it with the full\n" +
           "diagnostic output so the code can be assigned.")

    return db
}