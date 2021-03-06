/*
Copyright (c) 2014, 2015 Kristopher Johnson

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/

import Foundation

// Keys used for property list and NSCoding
let InterpreterPropertyListKey = "InterpreterPropertyList"
let StateKey = "state"
let VariablesKey = "variables"
let ArrayCountKey = "arrayCount"
let ArrayValuesKey = "arrayValues"
let InputLineBufferKey = "inputLineBuffer"
let ProgramKey = "program"
let ProgramIndexKey = "programIndex"
let ReturnStackKey = "returnStack"
let IsTraceOnKey = "isTraceOn"
let HasReachedEndOfInputKey = "hasReachedEndOfInput"
let InputLvaluesKey = "inputLvalues"
let StateBeforeInputKey = "stateBeforeInput"


/// State of the interpreter
///
/// The interpreter begins in the `.Idle` state, which
/// causes it to immediately display a statement prompt
/// and then enter the `.ReadingStatement` state, where it
/// will process numbered and unnumbered statements.
///
/// A `RUN` statement will put it into `.Running` state, and it
/// will execute the stored program.  If an `INPUT` statement
/// is executed, the interpreter will go into .ReadingInput
/// state until valid input is received, and it will return
/// to `.Running` state.
///
/// The state returns to `.ReadingStatement` on an `END`
/// statement or if `RUN` has to abort due to an error.
public enum InterpreterState: Int {
    /// Interpreter is not "doing anything".
    /// 
    /// When in this state, interpreter will display
    /// statement prompt and then enter the
    /// `ReadingStatement` state.
    case Idle

    /// Interpreter is trying to read a statement/command
    case ReadingStatement

    /// Interpreter is running a program
    case Running

    /// Interpreter is processing an `INPUT` statement
    case ReadingInput
}


// MARK: - Interpreter

/// Tiny Basic interpreter
public final class Interpreter: NSObject, NSCoding {
    /// Interpreter state
    var state: InterpreterState = .Idle

    /// Variable values
    var v: VariableBindings = Dictionary()

    /// Array of numbers, addressable using the syntax "@(i)"
    var a: [Number] = Array(count: 1024, repeatedValue: 0)

    /// Characters that have been read from input but not yet been returned by readInputLine()
    var inputLineBuffer: InputLine = Array()

    /// Low-level I/O interface
    ///
    /// This member is `public` so that it can be manipulated by
    /// unit tests.  Production code should not change it
    /// after an Interpreter is initialized.
    public weak var io: InterpreterIO?

    /// Array of program lines
    var program: Program = Array()

    /// Index of currently executing line in program
    var programIndex: Int = 0

    /// Return stack used by GOSUB/RETURN
    var returnStack: [Int] = Array()

    /// If true, print line numbers while program runs
    var isTraceOn = false

    /// If true, have encountered EOF while processing input
    var hasReachedEndOfInput = false

    /// Lvalues being read by current INPUT statement
    var inputLvalues: [Lvalue] = Array()

    /// State that interpreter was in when INPUT was called
    var stateBeforeInput: InterpreterState = .Idle


    // MARK: - Constructor

    /// Initializer
    ///
    /// The intepreter keeps a weak reference to `interpreterIO`,
    /// so it is the caller's responsibility to ensure that the
    /// reference remains valid for the lifetime of the interpreter.
    public init(interpreterIO: InterpreterIO) {
        io = interpreterIO
        super.init()
        clearVariablesAndArray()
    }


    // MARK: - NSCoding

    /// Return the state of the interpreter as a property-list dictionary.
    ///
    /// This property list can be used to restore interpreter state
    /// with restoreStateFromPropertyList()
    public func stateAsPropertyList() -> NSDictionary {
        let dict = NSMutableDictionary()

        // state
        dict[StateKey] = state.rawValue

        // v
        //
        // We encode only the non-zero values
        let vValues = NSMutableDictionary()
        for varname in v.keys {
            let value = v[varname]
            if value != 0 {
                let varnameKey = NSNumber(unsignedChar: varname)
                vValues[varnameKey] = value
            }
        }
        dict[VariablesKey] = vValues

        // a
        //
        // To encode the (probably sparse) array, we note the size and then
        // save only the non-zero values
        dict[ArrayCountKey] = a.count
        let aValues = NSMutableDictionary()
        for i in 0..<a.count {
            let value = a[i]
            if value != 0 {
                let key: NSNumber = i
                aValues[key] = value
            }
        }
        dict[ArrayValuesKey] = aValues

        // inputLineBuffer
        let inputLineData = NSData(bytes: &inputLineBuffer, length: inputLineBuffer.count)
        dict[InputLineBufferKey] = inputLineData

        // program
        let programText: NSString = programAsString()
        dict[ProgramKey] = programText

        // programIndex
        dict[ProgramIndexKey] = programIndex

        // inputLvalues
        let lvalues = NSMutableArray()
        for lv in inputLvalues {
            lvalues.addObject(lv.listText)
        }
        dict[InputLvaluesKey] = lvalues

        // isTraceOn
        dict[IsTraceOnKey] = isTraceOn

        // hasReachedEndOfInput
        dict[HasReachedEndOfInputKey] = hasReachedEndOfInput

        // stateBeforeInput
        dict[StateBeforeInputKey] = stateBeforeInput.rawValue

        return dict
    }

    /// Set interpreter's properties using archived state produced by stateAsPropertyList()'
    public func restoreStateFromPropertyList(dict: NSDictionary) {

        // Note: The "simple" elements like `state`, `hasReachedEndOfInput`, etc. are restored
        // after restoring the more complex elements, which may themselves make changes
        // to those simple members as part of their restoration process.

        // v
        if let vValues = dict[VariablesKey] as? NSDictionary {
            for (key, value) in vValues {
                if let key = key as? NSNumber {
                    if let value = value as? NSNumber {
                        let varname: Char = key.unsignedCharValue
                        v[varname] = value.integerValue
                    }
                    else {
                        assert(false, "\(VariablesKey) value is not NSNumber")
                    }
                }
                else {
                    assert(false, "\(VariablesKey) key is not NSNumber")
                }
            }
        }
        else {
            assert(false, "unable to decode \(VariablesKey)")
        }

        // a
        if let arraySize = dict[ArrayCountKey] as? NSNumber {
            a = Array(count: arraySize.integerValue, repeatedValue: 0)
            if let aValues = dict[ArrayValuesKey] as? NSDictionary {
                for (key, value) in aValues {
                    if let key = key as? NSNumber {
                        if let value = value as? NSNumber {
                            a[key.integerValue] = value.integerValue
                        }
                        else {
                            assert(false, "\(ArrayValuesKey) value is not NSNumber")
                        }
                    }
                    else {
                        assert(false, "\(ArrayValuesKey) key is not NSNumber")
                    }
                }
            }
            else {
                assert(false, "unable to decode \(ArrayValuesKey)")
            }
        }
        else {
            assert(false, "unable to decode \(ArrayCountKey)")
        }

        // inputLineBuffer
        if let inputLineData = dict[InputLineBufferKey] as? NSData {
            let length = inputLineData.length
            inputLineBuffer = Array(count: length, repeatedValue: 0)
            inputLineData.getBytes(&inputLineBuffer, length: length)
        }
        else {
            assert(false, "unable to decode \(InputLineBufferKey)")
        }

        // program
        if let programText = dict[ProgramKey] as? NSString {
            interpretString(programText as String)
        }
        else {
            assert(false, "unable to decode \(ProgramKey)")
        }

        // programIndex
        if let pi = dict[ProgramIndexKey] as? NSNumber {
            programIndex = pi.integerValue
        }
        else {
            assert(false, "unable to decode \(ProgramIndexKey)")
        }

        // inputLvalues
        if let lvalues = dict[InputLvaluesKey] as? NSArray {
            for lvText in lvalues {
                if let lvText = lvText as? NSString {
                    if let lv = lvalue(lvText as String) {
                        inputLvalues.append(lv)
                    }
                    else {
                        assert(false, "unable to parse \(lvText) as lvalue")
                    }
                }
                else {
                    assert(false, "\(InputLvaluesKey) value is not NSString")
                }
            }
        }
        else {
            assert(false, "unable to decode \(InputLvaluesKey)")
        }

        // isTraceOn
        if let ito = dict[IsTraceOnKey] as? NSNumber {
            isTraceOn = ito.boolValue
        }
        else {
            assert(false, "unable to decode \(IsTraceOnKey)")
        }

        // hasReachedEndOfInput
        if let hreof = dict[HasReachedEndOfInputKey] as! NSNumber? {
            hasReachedEndOfInput = hreof.boolValue
        }
        else {
            assert(false, "unable to decode \(hasReachedEndOfInput)")
        }

        // stateBeforeInput
        if let sbi = dict[StateBeforeInputKey] as? NSNumber {
            stateBeforeInput = InterpreterState(rawValue: sbi.integerValue) ?? .Idle
        }
        else {
            assert(false, "unable to decode \(StateBeforeInputKey)")
        }

        if let st = dict[StateKey] as? NSNumber {
            state = InterpreterState(rawValue: st.integerValue) ?? .Idle
        }
        else {
            assert(false, "unable to decode \(StateKey)")
        }
    }

    /// Encodes the interpreter's state with the given archiver
    ///
    /// Note that this does not retain the reference to the InterpreterIO object.
    public func encodeWithCoder(coder: NSCoder) {
        let propertyList = stateAsPropertyList()
        coder.encodeObject(propertyList, forKey: InterpreterPropertyListKey)
    }
    
    /// Initialize the object using archived state produced by encodeWithCoder()
    public init(coder: NSCoder) {
        super.init()

        // Note: cannot decode the InterpreterIO reference; owner must set it
        // after initialization
        self.io = nil

        if let propertyList = coder.decodeObjectForKey(InterpreterPropertyListKey) as? NSDictionary {
            restoreStateFromPropertyList(propertyList)
        }
        else {
            assert(false, "unable to retrieve \(InterpreterPropertyListKey)")
        }
    }

    /// Return the entire program listing as a single String
    func programAsString() -> String {
        var programText = ""
        for (lineNumber, stmt) in program {
            programText.extend("\(lineNumber) \(stmt.listText)\n")
        }
        return programText
    }

    /// Interpret a String
    func interpretString(s: String) {
        let chars = Array<UInt8>(s.utf8)
        let charCount = chars.count
        var index = 0
        loop: while true {
            let maybeInputLine = getInputLine {
                if index >= charCount {
                    return .EndOfStream
                }
                else {
                    return .Value(chars[index++])
                }
            }

            switch maybeInputLine {

            case let .Value(inputLine): processInput(inputLine)

            case .EndOfStream:
                break loop

            case .Waiting:
                assert(false, "getInputLine() for pasteboard should never return .Waiting")
                break loop
            }
        }
    }


    // MARK: Initialization/reset

    /// Set values of all variables and array elements to zero
    func clearVariablesAndArray() {
        for varname in Ch_A...Ch_Z {
            v[varname] = 0
        }
        for i in 0..<a.count {
            a[i] = 0
        }
    }

    /// Remove program from memory
    func clearProgram() {
        program = []
        programIndex = 0
        state = .Idle
    }

    /// Remove all items from the return stack
    func clearReturnStack() {
        returnStack = []
    }


    // MARK: - Top-level loop

    /// Display prompt and read input lines and interpret them until end of input.
    /// 
    /// This method should only be used when `InterpreterIO.getInputChar()`
    /// will never return `InputCharResult.Waiting`.
    /// Otherwise, host should call `next()` in a loop.
    public func runUntilEndOfInput() {
        hasReachedEndOfInput = false
        do {
            next()
        } while !hasReachedEndOfInput
    }

    /// Perform next operation.
    /// 
    /// The host can drive the interpreter by calling `next()`
    /// in a loop.
    public func next() {
        switch state {

        case .Idle:
            io?.showCommandPromptForInterpreter(self)
            state = .ReadingStatement

        case .ReadingStatement:
            switch readInputLine() {
            case let .Value(input): processInput(input)
            case .EndOfStream:      hasReachedEndOfInput = true
            case .Waiting:          break
            }

        case .Running:
            executeNextProgramStatement()

        case .ReadingInput:
            continueInput()
        }
    }

    /// Halt execution
    public func breakExecution() {
        sw: switch state {

        case .Running, .ReadingInput:
            if programIndex < program.count {
                let (lineNumber, _) = program[programIndex]
                showError("BREAK at line \(lineNumber)")
                break sw
            }
            // If for some reason programIndex is not valid, then fall through
            fallthrough

        case .Idle, .ReadingStatement:
            showError("BREAK")
        }

        state = .Idle
    }

    /// Parse an input line and execute it or add it to the program
    func processInput(input: InputLine) {
        state = .Idle

        let line = parseInputLine(input)

        switch line {
        case let .UnnumberedStatement(stmt):    execute(stmt)
        case let .NumberedStatement(num, stmt): insertLineIntoProgram(num, stmt)
        case let .EmptyNumberedLine(num):       deleteLineFromProgram(num)
        case .Empty:                            break
        case let .Error(message):               showError(message)
        }
    }


    // MARK: - Parsing

    func parseInputLine(input: InputLine) -> Line {
        let start = InputPosition(input, 0)

        let afterSpaces = start.afterSpaces()

        // If there are no non-space characters, skip this line
        if afterSpaces.isAtEndOfLine {
            return .Empty
        }

        // If line starts with a number, add the statement to the program
        if let (num, afterNum) = numberLiteral(afterSpaces) {
            if afterNum.isRemainingLineEmpty {
                return .EmptyNumberedLine(num)
            }

            if let (stmt, afterStmt) = statement(afterNum) {
                if afterStmt.isRemainingLineEmpty {
                    return .NumberedStatement(num, stmt)
                }
                else {
                    return .Error("line \(num): error: not a valid statement")
                }
            }
            else {
                return .Error("line \(num): error: not a valid statement")
            }
        }

        // Otherwise, try to execute statement immediately
        if let (stmt, afterStmt) = statement(afterSpaces) {
            if afterStmt.isRemainingLineEmpty {
                return .UnnumberedStatement(stmt)
            }
            else {
                return .Error("error: not a valid statement")
            }
        }
        else {
            return .Error("error: not a valid statement")
        }
    }


    // MARK: - Program editing

    func insertLineIntoProgram(lineNumber: Number, _ statement: Statement) {
        if let replaceIndex = indexOfProgramLineWithNumber(lineNumber) {
            program[replaceIndex] = (lineNumber, statement)
        }
        else if lineNumber > getLastProgramLineNumber() {
            program.append(lineNumber, statement)
        }
        else {
            // TODO: Rather than appending element and re-sorting, it would
            // probably be more efficient to find the correct insertion location
            // and do an insert operation.

            program.append(lineNumber, statement)

            // Re-sort by line numbers
            program.sort { $0.0 < $1.0 }
        }
    }

    /// Delete the line with the specified number from the program.
    ///
    /// No effect if there is no such line.
    func deleteLineFromProgram(lineNumber: Number) {
        if let index = indexOfProgramLineWithNumber(lineNumber) {
            program.removeAtIndex(index)
        }
    }

    /// Return the index into `program` of the line with the specified number
    func indexOfProgramLineWithNumber(lineNumber: Number) -> Int? {
        for (index, element) in enumerate(program) {
            let (n, statement) = element
            if lineNumber == n {
                return index
            }
        }
        return nil
    }

    /// Return line number of the last line in the program.
    ///
    /// Returns 0 if there is no program.
    func getLastProgramLineNumber() -> Number {
        if program.count > 0 {
            let (lineNumber, _) = program.last!
            return lineNumber
        }

        return 0
    }


    // MARK: - Execution

    /// Execute the given statement
    func execute(stmt: Statement) {
        switch stmt {
        case let .Print(exprList):           PRINT(exprList)
        case .PrintNewline:                  PRINT()
        case let .Input(lvalueList):         INPUT(lvalueList)
        case let .Let(lvalue, expr):         LET(lvalue, expr)
        case let .DimArray(expr):            DIM(expr)
        case let .If(lhs, relop, rhs, stmt): IF(lhs, relop, rhs, stmt)
        case let .Goto(expr):                GOTO(expr)
        case let .Gosub(expr):               GOSUB(expr)
        case .Return:                        RETURN()
        case let .List(range):               LIST(range)
        case let .Save(filename):            SAVE(filename)
        case let .Load(filename):            LOAD(filename)
        case .Files:                         FILES()
        case .ClipSave:                      CLIPSAVE()
        case .ClipLoad:                      CLIPLOAD()
        case .Run:                           RUN()
        case .End:                           END()
        case .Clear:                         CLEAR()
        case .Rem(_):                        break
        case .Tron:                          isTraceOn = true
        case .Troff:                         isTraceOn = false
        case .Bye:                           BYE()
        case .Help:                          HELP()
        }
    }

    /// Execute PRINT statement
    func PRINT(plist: PrintList) {
        switch plist {
        case let .Item(item, terminator):
            writeOutput(item)
            writeOutput(terminator)

        case let .Items(item, sep, printList):
            // Print the first item
            writeOutput(item)
            writeOutput(sep)

            // Walk the list to print remaining items
            var remainder = printList.value
            loop: while true {
                switch remainder {
                case let .Item(item, terminator):
                    // last item
                    writeOutput(item)
                    writeOutput(terminator)
                    break loop
                case let .Items(head, sep, tail):
                    writeOutput(head)
                    writeOutput(sep)
                    remainder = tail.value
                }
            }
        }
    }

    /// Execute PRINT statement with no arguments
    func PRINT() {
        writeOutputString("\n")
    }

    /// Execute INPUT statement
    /// 
    /// All values must be on a single input line, separated by commas.
    func INPUT(lvalueList: LvalueList) {
        inputLvalues = lvalueList.asArray
        stateBeforeInput = state
        continueInput()
    }

    /// Perform an INPUT operation
    ///
    /// This may be called by INPUT(), or by next() if resuming an operation
    /// following a .Waiting result from readInputLine()
    func continueInput() {

        /// Display a message to the user indicating what they are supposed to do
        func showHelpMessage() {
            if inputLvalues.count > 1 {
                showError("You must enter a comma-separated list of \(inputLvalues.count) values.")
            }
            else {
                showError("You must enter a value.")
            }
        }

        // Loop until successful or we hit end of input or a wait condition
        inputLoop: while true {
            io?.showInputPromptForInterpreter(self)
            switch readInputLine() {
            case let .Value(input):
                var pos = InputPosition(input, 0)

                for (index, lvalue) in enumerate(inputLvalues) {
                    if index == 0 {
                        if let (num, afterNum) = inputExpression(v, pos) {
                            assignToLvalue(lvalue, number: num)
                            pos = afterNum
                        }
                        else {
                            showHelpMessage()
                            continue inputLoop
                        }
                    }
                    else if let (comma, afterComma) = literal(",", pos) {
                        if let (num, afterNum) = inputExpression(v, afterComma) {
                            assignToLvalue(lvalue, number: num)
                            pos = afterNum
                        }
                        else {
                            showHelpMessage()
                            continue inputLoop
                        }
                    }
                    else {
                        showHelpMessage()
                        continue inputLoop
                    }
                }

                // If we get here, we've read input for all the variables
                switch stateBeforeInput {
                case .Running:
                    state = .Running
                default:
                    state = .Idle
                }

                break inputLoop

            case .Waiting:
                state = .ReadingInput
                break inputLoop

            case .EndOfStream:
                abortRunWithErrorMessage("error: INPUT - end of input stream")
                break inputLoop
            }
        }
    }

    /// Execute LET statement
    func LET(lvalue: Lvalue, _ expression: Expression) {
        assignToLvalue(lvalue, number: expression.evaluate(v, a))
    }

    /// Assign a new value for a specified Lvalue
    func assignToLvalue(lvalue: Lvalue, number: Number) {
        switch lvalue {
        case let .Var(variableName):
            v[variableName] = number

        case let .ArrayElement(indexExpr):
            let index = indexExpr.evaluate(v, a) % a.count
            if index < 0 {
                a[a.count + index] = number
            }
            else {
                a[index] = number
            }
        }
    }

    /// Execute DIM @() statement
    func DIM(expr: Expression) {
        let newCount = expr.evaluate(v, a)
        if newCount < 0 {
            abortRunWithErrorMessage("error: DIM - size cannot be negative")
            return
        }

        a = Array(count: newCount, repeatedValue: 0)
    }

    /// Execute IF statement
    func IF(lhs: Expression, _ relop: RelOp, _ rhs: Expression, _ stmt: Box<Statement>) {
        if relop.isTrueForNumbers(lhs.evaluate(v, a), rhs.evaluate(v, a)) {
            execute(stmt.value)
        }
    }

    /// Execute LIST statement with no arguments
    func LIST(range: ListRange) {
        func write(lineNumber: Number, stmt: Statement) {
            writeOutputString("\(lineNumber) \(stmt.listText)\n")
        }

        switch range {
        case .All:
            for (lineNumber, stmt) in program {
                write(lineNumber, stmt)
            }

        case let .SingleLine(expr):
            let listLineNumber = expr.evaluate(v, a)
            for (lineNumber, stmt) in program {
                if lineNumber == listLineNumber {
                    write(lineNumber, stmt)
                    break
                }
            }

        case let .Range(from, to):
            let fromLineNumber = from.evaluate(v, a)
            let toLineNumber = to.evaluate(v, a)
            
            let lineRange = ClosedInterval(fromLineNumber, toLineNumber)

            for (lineNumber, stmt) in program {
                if lineRange.contains(lineNumber) {
                    write(lineNumber, stmt)
                }
            }
        }
    }

    /// Execute SAVE statement
    func SAVE(filename: String) {
        let filenameCString = (filename as NSString).UTF8String
        let modeCString = ("w" as NSString).UTF8String

        let file = fopen(filenameCString, modeCString)
        if file != nil {
            for (lineNumber, stmt) in program {
                let outputLine = "\(lineNumber) \(stmt.listText)\n"
                let outputLineChars = charsFromString(outputLine)
                fwrite(outputLineChars, 1, outputLineChars.count, file)
            }
            fclose(file)
        }
        else {
            abortRunWithErrorMessage("error: SAVE - unable to open file \"\(filename)\": \(errnoMessage())")
        }
    }

    /// Execute LOAD statement
    func LOAD(filename: String) {
        let filenameCString = (filename as NSString).UTF8String
        let modeCString = ("r" as NSString).UTF8String

        let file = fopen(filenameCString, modeCString)
        if file != nil {
            // Read lines until end-of-stream or error
            loop: while true {
                let maybeInputLine = getInputLine {
                    let c = fgetc(file)
                    return (c == EOF) ? .EndOfStream : .Value(Char(c))
                }

                switch maybeInputLine {

                case let .Value(inputLine): processInput(inputLine)

                case .EndOfStream:
                    break loop

                case .Waiting:
                    assert(false, "getInputLine() for file should never return .Waiting")
                    break loop
                }
            }

            // If we got an error, report it
            if ferror(file) != 0 {
                abortRunWithErrorMessage("error: LOAD - read error for file \"\(filename)\": \(errnoMessage())")
            }

            fclose(file)
        }
        else {
            abortRunWithErrorMessage("error: LOAD - unable to open file \"\(filename)\": \(errnoMessage())")
        }
    }

    func FILES() {
        // Get current working directory
        var wdbuf: [Int8] = Array(count: Int(MAXNAMLEN), repeatedValue: 0)
        let workingDirectory = getcwd(&wdbuf, Int(MAXNAMLEN))

        // Open the directory
        let dir = opendir(workingDirectory)
        if dir != nil {
            // Use readdir to get each element
            var dirent = readdir(dir)
            while dirent != nil {
                if Int32(dirent.memory.d_type) != DT_DIR {
                    var name: [CChar] = Array()

                    // dirent.d_name is defined as a tuple with
                    // MAXNAMLEN elements.  The only way to
                    // iterate over those elements is via
                    // reflection
                    //
                    // Credit: dankogi at http://stackoverflow.com/questions/24299045/any-way-to-iterate-a-tuple-in-swift

                    let d_namlen = dirent.memory.d_namlen
                    let d_name = dirent.memory.d_name
                    let mirror = reflect(d_name)
                    for i in 0..<d_namlen {
                        let (s, m) = mirror[Int(i)]
                        name.append(m.value as! Int8)
                    }

                    // null-terminate it and convert to a String
                    name.append(0)
                    if let s = String.fromCString(name) {
                        writeOutputString("\(s)\n")
                    }
                }
                dirent = readdir(dir)
            }
            closedir(dir)
        }
    }

    /// Execute CLIPLOAD statement
    func CLIPLOAD() {
        if let s = getPasteboardContents() {
            interpretString(s)
        }
        else {
            abortRunWithErrorMessage("error: CLIPLOAD - unable to read text from clipboard")
            return
        }
    }

    /// Execute CLIPSAVE statement
    func CLIPSAVE() {
        var programText = programAsString()

        if programText.isEmpty {
            abortRunWithErrorMessage("error: CLIPSAVE: no program in memory")
            return
        }

        copyToPasteboard(programText)
    }

    /// Execute RUN statement
    func RUN() {
        if program.count == 0 {
            showError("error: RUN - no program in memory")
            return
        }

        programIndex = 0
        clearVariablesAndArray()
        clearReturnStack()
        state = .Running
    }

    /// Execute END statement
    func END() {
        state = .Idle
    }

    /// Execute GOTO statement
    func GOTO(expr: Expression) {
        let lineNumber = expr.evaluate(v, a)
        if let i = indexOfProgramLineWithNumber(lineNumber) {
            programIndex = i
            state = .Running
        }
        else {
            abortRunWithErrorMessage("error: GOTO \(lineNumber) - no line with that number")
        }
    }

    /// Execute GOSUB statement
    func GOSUB(expr: Expression) {
        let lineNumber = expr.evaluate(v, a)
        if let i = indexOfProgramLineWithNumber(lineNumber) {
            returnStack.append(programIndex)
            programIndex = i
            state = .Running
        }
        else {
            abortRunWithErrorMessage("error: GOSUB \(lineNumber) - no line with that number")
        }
    }

    /// Execute RETURN statement
    func RETURN() {
        if returnStack.count > 0 {
            programIndex = returnStack.last!
            returnStack.removeLast()
        }
        else {
            abortRunWithErrorMessage("error: RETURN - empty return stack")
        }
    }

    /// Reset the machine to initial state
    public func CLEAR() {
        clearProgram()
        clearReturnStack()
        clearVariablesAndArray()
    }

    /// Execute BYE statement
    public func BYE() {
        state = .Idle;
        io?.byeForInterpreter(self)
    }

    /// Execute HELP statement
    public func HELP() {
        let lines = [
            "Enter a line number and a BASIC statement to add it to the program.  Enter a statement without a line number to execute it immediately.",
            "",
            "Statements:",
            "  BYE",
            "  CLEAR",
            "  CLIPLOAD",
            "  CLIPSAVE",
            "  END",
            "  FILES",
            "  GOSUB expression",
            "  GOTO expression",
            "  HELP",
            "  IF condition THEN statement",
            "  INPUT var-list",
            "  LET var = expression",
            "  LIST [firstLine [, lastLine]]",
            "  LOAD \"filename\"",
            "  PRINT expr-list",
            "  REM comment",
            "  RETURN",
            "  RUN",
            "  SAVE \"filename\"",
            "  TRON | TROFF",
            "",
            "Example:",
            "  10 print \"Hello, world!\"",
            "  20 end",
            "  list",
            "  run"
        ]

        for line in lines {
            writeOutputString(line)
            writeOutputString("\n")
        }
    }

    func executeNextProgramStatement() {
        assert(state == .Running, "should only be called in Running state")

        if programIndex >= program.count {
            showError("error: RUN - program does not terminate with END")
            state = .Idle
            return
        }

        let (lineNumber, stmt) = program[programIndex]
        if isTraceOn {
            io?.showDebugTraceMessage("[\(lineNumber)]", forInterpreter: self)
        }
        ++programIndex
        execute(stmt)
    }

    /// Display error message and stop running
    ///
    /// Call this method if an unrecoverable error happens while executing a statement
    func abortRunWithErrorMessage(message: String) {
        showError(message)
        switch state {
        case .Running, .ReadingInput:
            showError("abort: program terminated")
        default:
            break
        }
        state = .Idle
    }


    // MARK: - I/O

    /// Send a single character to the output stream
    func writeOutputChar(c: Char) {
        io?.putOutputChar(c, forInterpreter: self)
    }

    /// Send characters to the output stream
    func writeOutputChars(chars: [Char]) {
        for c in chars {
            io?.putOutputChar(c, forInterpreter: self)
        }
    }

    /// Send string to the output stream
    func writeOutputString(s: String) {
        return writeOutputChars(charsFromString(s))
    }

    /// Print an object that conforms to the PrintTextProvider protocol
    func writeOutput(p: PrintTextProvider) {
        writeOutputChars(p.printText(v, a))
    }

    /// Display error message
    func showError(message: String) {
        io?.showErrorMessage(message, forInterpreter: self)
    }

    /// Read a line using the InterpreterIO interface.
    /// 
    /// Return array of characters, or nil if at end of input stream.
    ///
    /// Result does not include any non-graphic characters that were in the input stream.
    /// Any horizontal tab ('\t') in the input will be converted to a single space.
    ///
    /// Result may be an empty array, indicating an empty input line, not end of input.
    func readInputLine() -> InputLineResult {
        if let io = io {
            return getInputLine { io.getInputCharForInterpreter(self) }
        }
        else {
            return .EndOfStream
        }
    }

    /// Get a line of input, using specified function to retrieve characters.
    /// 
    /// Result does not include any non-graphic characters that were in the input stream.
    /// Any horizontal tab ('\t') in the input will be converted to a single space.
    func getInputLine(getChar: () -> InputCharResult) -> InputLineResult {
        loop: while true {
            switch getChar() {
            case let .Value(c):
                if c == Ch_Linefeed {
                    let result = InputLineResult.Value(inputLineBuffer)
                    inputLineBuffer = Array()
                    return result
                }
                else if c == Ch_Tab {
                    // Convert tabs to spaces
                    inputLineBuffer.append(Ch_Space)
                }
                else if isGraphicChar(c) {
                    inputLineBuffer.append(c)
                }

            case .EndOfStream:
                if inputLineBuffer.count > 0 {
                    let result = InputLineResult.Value(inputLineBuffer)
                    inputLineBuffer = Array()
                    return result
                }
                return .EndOfStream

            case .Waiting:
                return .Waiting
            }
        }
    }
}
