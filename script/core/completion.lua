local sp           = require 'bee.subprocess'
local define       = require 'proto.define'
local files        = require 'files'
local searcher     = require 'core.searcher'
local matchKey     = require 'core.matchkey'
local vm           = require 'vm'
local getName      = require 'core.hover.name'
local getArg       = require 'core.hover.arg'
local getHover     = require 'core.hover'
local config       = require 'config'
local util         = require 'utility'
local markdown     = require 'provider.markdown'
local parser       = require 'parser'
local keyWordMap   = require 'core.keyword'
local workspace    = require 'workspace'
local furi         = require 'file-uri'
local rpath        = require 'workspace.require-path'
local lang         = require 'language'
local lookBackward = require 'core.look-backward'
local guide        = require 'parser.guide'
local infer        = require 'core.infer'

local DiagnosticModes = {
    'disable-next-line',
    'disable-line',
    'disable',
    'enable',
}

local stackID = 0
local stacks = {}
local function stack(callback)
    stackID = stackID + 1
    stacks[stackID] = callback
    return stackID
end

local function clearStack()
    stacks = {}
end

local function resolveStack(id)
    local callback = stacks[id]
    if not callback then
        log.warn('Unknown resolved id', id)
        return nil
    end

    return callback()
end

local function trim(str)
    return str:match '^%s*(%S+)%s*$'
end

local function findNearestSource(ast, offset)
    local source
    guide.eachSourceContain(ast.ast, offset, function (src)
        source = src
    end)
    return source
end

local function findNearestTableField(ast, offset)
    local source
    guide.eachSourceContain(ast.ast, offset, function (src)
        if src.type == 'table'
        or src.type == 'tablefield'
        or src.type == 'tableindex'
        or src.type == 'tableexp' then
            source = src
        end
    end)
    return source
end

local function findParent(ast, text, offset)
    for i = offset, 1, -1 do
        local char = text:sub(i, i)
        if lookBackward.isSpace(char) then
            goto CONTINUE
        end
        local oop
        if char == '.' then
            -- `..` 的情况
            if text:sub(i-1, i-1) == '.' then
                return nil, nil
            end
            oop = false
        elseif char == ':' then
            oop = true
        else
            return nil, nil
        end
        local anyPos = lookBackward.findAnyPos(text, i-1)
        if not anyPos then
            return nil, nil
        end
        local parent = guide.eachSourceContain(ast.ast, anyPos, function (source)
            if source.finish == anyPos then
                return source
            end
        end)
        if parent then
            return parent, oop
        end
        ::CONTINUE::
    end
    return nil, nil
end

local function findParentInStringIndex(ast, text, offset)
    local near, nearStart
    guide.eachSourceContain(ast.ast, offset, function (source)
        local start = guide.getStartFinish(source)
        if not start then
            return
        end
        if not nearStart or nearStart < start then
            near = source
            nearStart = start
        end
    end)
    if not near or near.type ~= 'string' then
        return
    end
    local parent = near.parent
    if not parent or parent.index ~= near then
        return
    end
    -- index不可能是oop模式
    return parent.node, false
end

local function buildFunctionSnip(source, value, oop)
    local name = (getName(source) or ''):gsub('^.+[$.:]', '')
    local args = getArg(value, oop)
    local id = 0
    args = args:gsub('[^,]+', function (arg)
        id = id + 1
        return arg:gsub('^(%s*)(.+)', function (sp, word)
            return ('%s${%d:%s}'):format(sp, id, word)
        end)
    end)
    return ('%s(%s)'):format(name, args)
end

local function buildDetail(source)
    if source.type == 'dummy' then
        return
    end
    local types = infer.searchAndViewInfers(source)
    local literals = infer.searchAndViewLiterals(source)
    if literals then
        return types .. ' = ' .. literals
    else
        return types
    end
end

local function getSnip(source)
    local context = config.get 'Lua.completion.displayContext'
    if context <= 0 then
        return nil
    end
    local defs = vm.getRefs(source)
    for _, def in ipairs(defs) do
        def = searcher.getObjectValue(def) or def
        if def ~= source and def.type == 'function' then
            local uri = guide.getUri(def)
            local text = files.getText(uri)
            local lines = files.getLines(uri)
            if not text then
                goto CONTINUE
            end
            if vm.isMetaFile(uri) then
                goto CONTINUE
            end
            local row = guide.positionOf(lines, def.start)
            local firstRow = lines[row]
            local lastRow = lines[math.min(row + context - 1, #lines)]
            local snip = text:sub(firstRow.start, lastRow.finish)
            return snip
        end
        ::CONTINUE::
    end
end

local function buildDesc(source)
    if source.type == 'dummy' then
        return
    end
    local hover = getHover.get(source)
    local md = markdown()
    md:add('lua', hover.label)
    md:splitLine()
    md:add('md',  hover.description)
    md:splitLine()
    md:add('lua', getSnip(source))
    return md:string()
end

local function buildFunction(results, source, value, oop, data)
    local snipType = config.get 'Lua.completion.callSnippet'
    if snipType == 'Disable' or snipType == 'Both' then
        results[#results+1] = data
    end
    if snipType == 'Both' or snipType == 'Replace' then
        local snipData = util.deepCopy(data)
        snipData.kind = define.CompletionItemKind.Snippet
        snipData.insertText = buildFunctionSnip(source, value, oop)
        snipData.insertTextFormat = 2
        snipData.command = {
            title = 'trigger signature',
            command = 'editor.action.triggerParameterHints',
        }
        snipData.id  = stack(function ()
            return {
                detail      = buildDetail(source),
                description = buildDesc(source),
            }
        end)
        results[#results+1] = snipData
    end
end

local function buildInsertRequire(ast, targetUri, stemName)
    local uri   = guide.getUri(ast.ast)
    local lines = files.getLines(uri)
    local text  = files.getText(uri)
    local start = 1
    for i = 1, #lines do
        local ln = lines[i]
        local lnText = text:sub(ln.start, ln.finish)
        if not lnText:find('require', 1, true) then
            start = ln.start
            break
        end
    end
    local path = furi.decode(targetUri)
    local visiblePaths = rpath.getVisiblePath(path, config.get 'Lua.runtime.path', true)
    if not visiblePaths or #visiblePaths == 0 then
        return nil
    end
    table.sort(visiblePaths, function (a, b)
        return #a.expect < #b.expect
    end)
    return {
        {
            start   = start,
            finish  = start - 1,
            newText = ('local %s = require %q\n'):format(stemName, visiblePaths[1].expect)
        }
    }
end

local function isSameSource(ast, source, pos)
    if not files.eq(guide.getUri(source), guide.getUri(ast.ast)) then
        return false
    end
    if source.type == 'field'
    or source.type == 'method' then
        source = source.parent
    end
    return source.start <= pos and source.finish >= pos
end

local function getParams(func, oop)
    if not func.args then
        return '()'
    end
    local args = {}
    for _, arg in ipairs(func.args) do
        if arg.type == '...' then
            args[#args+1] = '...'
        elseif arg.type == 'doc.type.arg' then
            args[#args+1] = arg.name[1]
        else
            args[#args+1] = arg[1]
        end
    end
    if oop and args[1] ~= '...' then
        table.remove(args, 1)
    end
    return '(' .. table.concat(args, ', ') .. ')'
end

local function checkLocal(ast, word, offset, results)
    local locals = guide.getVisibleLocals(ast.ast, offset)
    for name, source in pairs(locals) do
        if isSameSource(ast, source, offset) then
            goto CONTINUE
        end
        if not matchKey(word, name) then
            goto CONTINUE
        end
        if name:sub(1, 1) == '@' then
            goto CONTINUE
        end
        if infer.hasType(source, 'function') then
            for _, def in ipairs(vm.getDefs(source)) do
                if def.type == 'function'
                or def.type == 'doc.type.function' then
                    local funcLabel = name .. getParams(def, false)
                    buildFunction(results, source, def, false, {
                        label  = funcLabel,
                        insertText = name,
                        kind   = define.CompletionItemKind.Function,
                        id     = stack(function ()
                            return {
                                detail      = buildDetail(source),
                                description = buildDesc(source),
                            }
                        end),
                    })
                end
            end
        else
            results[#results+1] = {
                label  = name,
                kind   = define.CompletionItemKind.Variable,
                id     = stack(function ()
                    return {
                        detail      = buildDetail(source),
                        description = buildDesc(source),
                    }
                end),
            }
        end
        ::CONTINUE::
    end
end

local function checkModule(ast, word, offset, results)
    if not config.get 'Lua.completion.autoRequire' then
        return
    end
    local locals  = guide.getVisibleLocals(ast.ast, offset)
    for uri in files.eachFile() do
        if files.eq(uri, guide.getUri(ast.ast)) then
            goto CONTINUE
        end
        local originUri = files.getOriginUri(uri)
        local path = furi.decode(originUri)
        local fileName = path:match '[^/\\]*$'
        local stemName = fileName:gsub('%..+', '')
        if  not locals[stemName]
        and not vm.hasGlobalSets(stemName)
        and not config.get 'Lua.diagnostics.globals'[stemName]
        and stemName:match '^[%a_][%w_]*$'
        and matchKey(word, stemName) then
            local targetAst = files.getState(uri)
            if not targetAst then
                goto CONTINUE
            end
            local targetReturns = targetAst.ast.returns
            if not targetReturns then
                goto CONTINUE
            end
            local targetSource = targetReturns[1] and targetReturns[1][1]
            if not targetSource then
                goto CONTINUE
            end
            if  targetSource.type ~= 'getlocal'
            and targetSource.type ~= 'table'
            and targetSource.type ~= 'function' then
                goto CONTINUE
            end
            if  targetSource.type == 'getlocal'
            and vm.isDeprecated(targetSource.node) then
                goto CONTINUE
            end
            results[#results+1] = {
                label  = stemName,
                kind   = define.CompletionItemKind.Variable,
                commitCharacters = {'.'},
                command = {
                    title     = 'autoRequire',
                    command   = 'lua.autoRequire:' .. sp:get_id(),
                    arguments = {
                        {
                            uri    = guide.getUri(ast.ast),
                            target = originUri,
                            name   = stemName,
                        },
                    },
                },
                id     = stack(function ()
                    return {
                        detail      = buildDetail(targetSource),
                        description = lang.script('COMPLETION_IMPORT_FROM', ('[%s](%s)'):format(
                            workspace.getRelativePath(originUri),
                            originUri
                        ))
                            .. '\n' .. buildDesc(targetSource),
                        --additionalTextEdits = buildInsertRequire(ast, originUri, stemName),
                    }
                end)
            }
        end
        ::CONTINUE::
    end
end

local function checkFieldFromFieldToIndex(name, src, parent, word, start, offset)
    if name:match '^[%a_][%w_]*$' then
        return nil
    end
    local textEdit, additionalTextEdits
    local uri = guide.getUri(parent)
    local text = files.getText(uri)
    local wordStart
    if word == '' then
        wordStart = text:match('()%S', start + 1) or (offset + 1)
    else
        wordStart = offset - #word + 1
    end
    local newText
    if vm.getKeyType(src) == 'string' then
        newText = ('[%q]'):format(name)
    else
        newText = ('[%s]'):format(name)
    end
    textEdit = {
        start   = wordStart,
        finish  = offset,
        newText = newText,
    }
    local nxt = parent.next
    if nxt then
        local dotStart
        if nxt.type == 'setfield'
        or nxt.type == 'getfield'
        or nxt.type == 'tablefield' then
            dotStart = nxt.dot.start
        elseif nxt.type == 'setmethod'
        or     nxt.type == 'getmethod' then
            dotStart = nxt.colon.start
        end
        if dotStart then
            additionalTextEdits = {
                {
                    start   = dotStart,
                    finish  = dotStart,
                    newText = '',
                }
            }
        end
    else
        if config.get 'Lua.runtime.version' == 'Lua 5.1'
        or config.get 'Lua.runtime.version' == 'LuaJIT' then
            textEdit.newText = '_G' .. textEdit.newText
        else
            textEdit.newText = '_ENV' .. textEdit.newText
        end
    end
    return textEdit, additionalTextEdits
end

local function checkFieldThen(name, src, word, start, offset, parent, oop, results)
    local value = searcher.getObjectValue(src) or src
    local kind = define.CompletionItemKind.Field
    if value.type == 'function'
    or value.type == 'doc.type.function' then
        if oop then
            kind = define.CompletionItemKind.Method
        else
            kind = define.CompletionItemKind.Function
        end
        buildFunction(results, src, value, oop, {
            label      = name,
            kind       = kind,
            insertText = name:match '^[^(]+',
            deprecated = vm.isDeprecated(src) or nil,
            id         = stack(function ()
                return {
                    detail      = buildDetail(src),
                    description = buildDesc(src),
                }
            end),
        })
        return
    end
    if oop and not infer.hasType(src, 'function') then
        return
    end
    local literal = guide.getLiteral(value)
    if literal ~= nil then
        kind = define.CompletionItemKind.Enum
    end
    local textEdit, additionalTextEdits
    if parent.next and parent.next.index then
        local str = parent.next.index
        textEdit = {
            start   = str.start + #str[2],
            finish  = offset,
            newText = name,
        }
    else
        textEdit, additionalTextEdits = checkFieldFromFieldToIndex(name, src, parent, word, start, offset)
    end
    results[#results+1] = {
        label      = name,
        kind       = kind,
        deprecated = vm.isDeprecated(src) or nil,
        textEdit   = textEdit,
        additionalTextEdits = additionalTextEdits,
        id         = stack(function ()
            return {
                detail      = buildDetail(src),
                description = buildDesc(src),
            }
        end)
    }
end

local function checkFieldOfRefs(refs, ast, word, start, offset, parent, oop, results, locals, isGlobal)
    local fields = {}
    local funcs  = {}
    local count = 0
    for _, src in ipairs(refs) do
        local name = vm.getKeyName(src)
        if not name then
            goto CONTINUE
        end
        if isSameSource(ast, src, start) then
            goto CONTINUE
        end
        if isGlobal and locals and locals[name] then
            goto CONTINUE
        end
        if not matchKey(word, name, count >= 100) then
            goto CONTINUE
        end
        local funcLabel
        if config.get 'Lua.completion.showParams' then
            local value = searcher.getObjectValue(src) or src
            if value.type == 'function'
            or value.type == 'doc.type.function' then
                funcLabel = name .. getParams(value, oop)
                fields[funcLabel] = src
                count = count + 1
                if value.type == 'function' and value.bindDocs then
                    for _, doc in ipairs(value.bindDocs) do
                        if doc.type == 'doc.overload' then
                            funcLabel = name .. getParams(doc.overload, oop)
                            fields[funcLabel] = doc.overload
                        end
                    end
                end
                funcs[name] = true
                if fields[name] and not guide.isSet(fields[name]) then
                    fields[name] = nil
                end
                goto CONTINUE
            end
        end
        local last = fields[name]
        if last == nil and not funcs[name] then
            fields[name] = src
            count = count + 1
            goto CONTINUE
        end
        if vm.isDeprecated(src) then
            goto CONTINUE
        end
        if guide.isSet(src) then
            fields[name] = src
            goto CONTINUE
        end
        ::CONTINUE::
    end
    for name, src in util.sortPairs(fields) do
        if src then
            checkFieldThen(name, src, word, start, offset, parent, oop, results)
        end
    end
end

local function checkGlobal(ast, word, start, offset, parent, oop, results)
    local locals = guide.getVisibleLocals(ast.ast, offset)
    local globals = vm.getGlobalSets '*'
    checkFieldOfRefs(globals, ast, word, start, offset, parent, oop, results, locals, 'global')
end

local function checkField(ast, word, start, offset, parent, oop, results)
    if parent.tag == '_ENV' or parent.special == '_G' then
        local globals = vm.getGlobalSets '*'
        checkFieldOfRefs(globals, ast, word, start, offset, parent, oop, results)
    else
        local refs = vm.getRefs(parent, '*')
        checkFieldOfRefs(refs, ast, word, start, offset, parent, oop, results)
    end
end

local function checkTableField(ast, word, start, results)
    local source = guide.eachSourceContain(ast.ast, start, function (source)
        if  source.start == start
        and source.parent
        and source.parent.type == 'table' then
            return source
        end
    end)
    if not source then
        return
    end
    local used = {}
    guide.eachSourceType(ast.ast, 'tablefield', function (src)
        if not src.field then
            return
        end
        local key = src.field[1]
        if  not used[key]
        and matchKey(word, key)
        and src ~= source then
            used[key] = true
            results[#results+1] = {
                label = key,
                kind  = define.CompletionItemKind.Property,
            }
        end
    end)
end

local function checkCommon(myUri, word, text, offset, results)
    results.enableCommon = true
    local used = {}
    for _, result in ipairs(results) do
        used[result.label:match '^[^(]*'] = true
    end
    for _, data in ipairs(keyWordMap) do
        used[data[1]] = true
    end
    if config.get 'Lua.completion.workspaceWord' and #word >= 2 then
        local myHead = word:sub(1, 2)
        for uri in files.eachFile() do
            if #results >= 100 then
                break
            end
            if myUri and files.eq(myUri, uri) then
                goto CONTINUE
            end
            local words = files.getWordsOfHead(uri, myHead)
            if not words then
                goto CONTINUE
            end
            for _, str in ipairs(words) do
                if #results >= 100 then
                    break
                end
                if  not used[str]
                and str ~= word then
                    used[str] = true
                    if matchKey(word, str) then
                        results[#results+1] = {
                            label = str,
                            kind  = define.CompletionItemKind.Text,
                        }
                    end
                end
            end
            ::CONTINUE::
        end
        for uri in files.eachDll() do
            if #results >= 100 then
                break
            end
            local words = files.getDllWords(uri) or {}
            for _, str in ipairs(words) do
                if #results >= 100 then
                    break
                end
                if #str >= 3 and not used[str] and str ~= word then
                    used[str] = true
                    if matchKey(word, str) then
                        results[#results+1] = {
                            label = str,
                            kind  = define.CompletionItemKind.Text,
                        }
                    end
                end
            end
        end
    end
    for str, pos in text:gmatch '([%a_][%w_]+)()' do
        if #results >= 100 then
            break
        end
        if #str >= 3 and not used[str] and pos - 1 ~= offset then
            used[str] = true
            if matchKey(word, str) then
                results[#results+1] = {
                    label = str,
                    kind  = define.CompletionItemKind.Text,
                }
            end
        end
    end
end

local function isInString(ast, offset)
    return guide.eachSourceContain(ast.ast, offset, function (source)
        if source.type == 'string' then
            return true
        end
    end)
end

local function checkKeyWord(ast, text, start, offset, word, hasSpace, afterLocal, results)
    local snipType = config.get 'Lua.completion.keywordSnippet'
    local symbol = lookBackward.findSymbol(text, start - 1)
    local isExp = symbol == '(' or symbol == ',' or symbol == '='
    local info = {
        hasSpace = hasSpace,
        isExp    = isExp,
        text     = text,
        start    = start,
        uri      = guide.getUri(ast.ast),
        offset   = offset,
        ast      = ast,
    }
    for _, data in ipairs(keyWordMap) do
        local key = data[1]
        local eq
        if hasSpace then
            eq = word == key
        else
            eq = matchKey(word, key)
        end
        if afterLocal and key ~= 'function' then
            eq = false
        end
        if not eq then
            goto CONTINUE
        end
        if isExp then
            if  key ~= 'nil'
            and key ~= 'true'
            and key ~= 'false'
            and key ~= 'function' then
                goto CONTINUE
            end
        end
        local replaced
        local extra
        if snipType == 'Both' or snipType == 'Replace' then
            local func = data[2]
            if func then
                replaced = func(info, results)
                extra = true
            end
        end
        if snipType == 'Both' then
            replaced = false
        end
        if not replaced then
            if not hasSpace then
                local item = {
                    label = key,
                    kind  = define.CompletionItemKind.Keyword,
                }
                if #results > 0 and extra then
                    table.insert(results, #results, item)
                else
                    results[#results+1] = item
                end
            end
        end
        local checkStop = data[3]
        if checkStop then
            local stop = checkStop(info)
            if stop then
                return true
            end
        end
        ::CONTINUE::
    end
end

local function checkProvideLocal(ast, word, start, results)
    local block
    guide.eachSourceContain(ast.ast, start, function (source)
        if source.type == 'function'
        or source.type == 'main' then
            block = source
        end
    end)
    if not block then
        return
    end
    local used = {}
    guide.eachSourceType(block, 'getglobal', function (source)
        if source.start > start
        and not used[source[1]]
        and matchKey(word, source[1]) then
            used[source[1]] = true
            results[#results+1] = {
                label = source[1],
                kind  = define.CompletionItemKind.Variable,
            }
        end
    end)
    guide.eachSourceType(block, 'getlocal', function (source)
        if source.start > start
        and not used[source[1]]
        and matchKey(word, source[1]) then
            used[source[1]] = true
            results[#results+1] = {
                label = source[1],
                kind  = define.CompletionItemKind.Variable,
            }
        end
    end)
end

local function checkFunctionArgByDocParam(ast, word, start, results)
    local func = guide.eachSourceContain(ast.ast, start, function (source)
        if source.type == 'function' then
            return source
        end
    end)
    if not func then
        return
    end
    local docs = func.bindDocs
    if not docs then
        return
    end
    local params = {}
    for _, doc in ipairs(docs) do
        if doc.type == 'doc.param' then
            params[#params+1] = doc
        end
    end
    local firstArg = func.args and func.args[1]
    if not firstArg
    or firstArg.start <= start and firstArg.finish >= start then
        local firstParam = params[1]
        if firstParam and matchKey(word, firstParam.param[1]) then
            local label = {}
            for _, param in ipairs(params) do
                label[#label+1] = param.param[1]
            end
            results[#results+1] = {
                label = table.concat(label, ', '),
                kind  = define.CompletionItemKind.Snippet,
            }
        end
    end
    for _, doc in ipairs(params) do
        if matchKey(word, doc.param[1]) then
            results[#results+1] = {
                label = doc.param[1],
                kind  = define.CompletionItemKind.Interface,
            }
        end
    end
end

local function isAfterLocal(text, start)
    local pos = lookBackward.skipSpace(text, start-1)
    local word = lookBackward.findWord(text, pos)
    return word == 'local'
end

local function checkUri(ast, text, offset, results)
    local collect = {}
    local myUri = guide.getUri(ast.ast)
    guide.eachSourceContain(ast.ast, offset, function (source)
        if source.type ~= 'string' then
            return
        end
        local callargs = source.parent
        if not callargs or callargs.type ~= 'callargs' then
            return
        end
        if callargs[1] ~= source then
            return
        end
        local call = callargs.parent
        local func = call.node
        local literal = guide.getLiteral(source)
        local libName = vm.getLibraryName(func)
        if not libName then
            return
        end
        if     libName == 'require' then
            for uri in files.eachFile() do
                uri = files.getOriginUri(uri)
                if files.eq(myUri, uri) then
                    goto CONTINUE
                end
                local path = workspace.getRelativePath(uri)
                local infos = rpath.getVisiblePath(path, config.get 'Lua.runtime.path')
                for _, info in ipairs(infos) do
                    if matchKey(literal, info.expect) then
                        if not collect[info.expect] then
                            collect[info.expect] = {
                                textEdit = {
                                    start   = source.start + #source[2],
                                    finish  = source.finish - #source[2],
                                    newText = info.expect,
                                }
                            }
                        end
                        if vm.isMetaFile(uri) then
                            collect[info.expect][#collect[info.expect]+1] = ('* [[meta]](%s)'):format(uri)
                        else
                            collect[info.expect][#collect[info.expect]+1] = ([=[* [%s](%s) %s]=]):format(
                                path,
                                uri,
                                lang.script('HOVER_USE_LUA_PATH', info.searcher)
                            )
                        end
                    end
                end
                ::CONTINUE::
            end
            for uri in files.eachDll() do
                local opens = files.getDllOpens(uri) or {}
                local path = workspace.getRelativePath(uri)
                for _, open in ipairs(opens) do
                    if matchKey(literal, open) then
                        if not collect[open] then
                            collect[open] = {
                                textEdit = {
                                    start   = source.start + #source[2],
                                    finish  = source.finish - #source[2],
                                    newText = open,
                                }
                            }
                        end
                        collect[open][#collect[open]+1] = ([=[* [%s](%s)]=]):format(
                            path,
                            uri
                        )
                    end
                end
            end
        elseif libName == 'dofile'
        or     libName == 'loadfile' then
            for uri in files.eachFile() do
                uri = files.getOriginUri(uri)
                if files.eq(myUri, uri) then
                    goto CONTINUE
                end
                if vm.isMetaFile(uri) then
                    goto CONTINUE
                end
                local path = workspace.getRelativePath(uri)
                if matchKey(literal, path) then
                    if not collect[path] then
                        collect[path] = {
                            textEdit = {
                                start   = source.start + #source[2],
                                finish  = source.finish - #source[2],
                                newText = path,
                            }
                        }
                    end
                    collect[path][#collect[path]+1] = ([=[[%s](%s)]=]):format(
                        path,
                        uri
                    )
                end
                ::CONTINUE::
            end
        end
    end)
    for label, infos in util.sortPairs(collect) do
        local mark = {}
        local des  = {}
        for _, info in ipairs(infos) do
            if not mark[info] then
                mark[info] = true
                des[#des+1] = info
            end
        end
        results[#results+1] = {
            label = label,
            kind  = define.CompletionItemKind.Reference,
            description = table.concat(des, '\n'),
            textEdit = infos.textEdit,
        }
    end
end

local function checkLenPlusOne(ast, text, offset, results)
    guide.eachSourceContain(ast.ast, offset, function (source)
        if source.type == 'getindex'
        or source.type == 'setindex' then
            local _, pos = text:find('%s*%[%s*%#', source.node.finish)
            if not pos then
                return
            end
            local nodeText = text:sub(source.node.start, source.node.finish)
            local writingText = trim(text:sub(pos + 1, offset - 1)) or ''
            if not matchKey(writingText, nodeText) then
                return
            end
            if source.parent == guide.getParentBlock(source) then
                -- state
                local label = text:match('%#[ \t]*', pos) .. nodeText .. '+1'
                local eq = text:find('^%s*%]?%s*%=', source.finish)
                local newText = label .. ']'
                if not eq then
                    newText = newText .. ' = '
                end
                results[#results+1] = {
                    label    = label,
                    kind     = define.CompletionItemKind.Snippet,
                    textEdit = {
                        start   = pos,
                        finish  = source.finish,
                        newText = newText,
                    },
                }
            else
                -- exp
                local label = text:match('%#[ \t]*', pos) .. nodeText
                local newText = label .. ']'
                results[#results+1] = {
                    label    = label,
                    kind     = define.CompletionItemKind.Snippet,
                    textEdit = {
                        start   = pos,
                        finish  = source.finish,
                        newText = newText,
                    },
                }
            end
        end
    end)
end

local function tryLabelInString(label, source)
    if not source or source.type ~= 'string' then
        return label
    end
    local str = parser:grammar(label, 'String')
    if not str then
        return label
    end
    if not matchKey(source[1], str[1]) then
        return nil
    end
    return util.viewString(str[1], source[2])
end

local function mergeEnums(a, b, source)
    local mark = {}
    for _, enum in ipairs(a) do
        mark[enum.label] = true
    end
    for _, enum in ipairs(b) do
        local label = tryLabelInString(enum.label, source)
        if label and not mark[label] then
            mark[label] = true
            local result = {
                label       = label,
                kind        = enum.kind,
                description = enum.description,
                insertText  = enum.insertText,
                textEdit    = source and {
                    start   = source.start,
                    finish  = source.finish,
                    newText = enum.insertText or label,
                },
            }
            a[#a+1] = result
        end
    end
end

local function checkTypingEnum(ast, text, offset, defs, str, results)
    local enums = {}
    for _, def in ipairs(defs) do
        if def.type == 'doc.type.enum'
        or def.type == 'doc.resume' then
            enums[#enums+1] = {
                label       = def[1],
                description = def.comment and def.comment.text,
                kind        = define.CompletionItemKind.EnumMember,
            }
        end
    end
    local myResults = {}
    mergeEnums(myResults, enums, str)
    table.sort(myResults, function (a, b)
        return a.label < b.label
    end)
    for _, res in ipairs(myResults) do
        results[#results+1] = res
    end
end

local function checkEqualEnumLeft(ast, text, offset, source, results)
    if not source then
        return
    end
    local str = guide.eachSourceContain(ast.ast, offset, function (src)
        if src.type == 'string' then
            return src
        end
    end)
    local defs = vm.getDefs(source)
    checkTypingEnum(ast, text, offset, defs, str, results)
end

local function checkEqualEnum(ast, text, offset, results)
    local start =  lookBackward.findTargetSymbol(text, offset, '=')
    if not start then
        return
    end
    local eqOrNeq
    if text:sub(start - 1, start - 1) == '='
    or text:sub(start - 1, start - 1) == '~' then
        start = start - 1
        eqOrNeq = true
    end
    start = lookBackward.skipSpace(text, start - 1)
    local source = findNearestSource(ast, start)
    if not source then
        return
    end
    if source.type == 'callargs' then
        source = source.parent
    end
    if source.type == 'call' and not eqOrNeq then
        return
    end
    checkEqualEnumLeft(ast, text, offset, source, results)
end

local function checkEqualEnumInString(ast, text, offset, results)
    local source = findNearestSource(ast, offset)
    local parent = source.parent
    if parent.type == 'binary' then
        if source ~= parent[2] then
            return
        end
        if not parent.op then
            return
        end
        if parent.op.type ~= '==' and parent.op.type ~= '~=' then
            return
        end
        checkEqualEnumLeft(ast, text, offset, parent[1], results)
    end
    if parent.type == 'local' then
        checkEqualEnumLeft(ast, text, offset, parent, results)
    end
    if parent.type == 'setlocal'
    or parent.type == 'setglobal'
    or parent.type == 'setfield'
    or parent.type == 'setindex' then
        checkEqualEnumLeft(ast, text, offset, parent.node, results)
    end
end

local function isFuncArg(ast, offset)
    return guide.eachSourceContain(ast.ast, offset, function (source)
        if source.type == 'funcargs' then
            return true
        end
    end)
end

local function trySpecial(ast, text, offset, results)
    if isInString(ast, offset) then
        checkUri(ast, text, offset, results)
        checkEqualEnumInString(ast, text, offset, results)
        return
    end
    -- x[#x+1]
    checkLenPlusOne(ast, text, offset, results)
    -- type(o) ==
    checkEqualEnum(ast, text, offset, results)
end

local function tryIndex(ast, text, offset, results)
    local parent, oop = findParentInStringIndex(ast, text, offset)
    if not parent then
        return
    end
    local word = parent.next.index[1]
    checkField(ast, word, offset, offset, parent, oop, results)
end

local function tryWord(ast, text, offset, triggerCharacter, results)
    local finish = lookBackward.skipSpace(text, offset)
    local word, start = lookBackward.findWord(text, offset)
    if not word then
        if triggerCharacter == nil then
            word = ''
            start = offset + 1
        else
            return nil
        end
    end
    local hasSpace = triggerCharacter ~= nil and finish ~= offset
    if isInString(ast, offset) then
        if not hasSpace then
            if #results == 0 then
                checkCommon(ast.uri, word, text, offset, results)
            end
        end
    else
        local parent, oop = findParent(ast, text, start - 1)
        if parent then
            if not hasSpace then
                checkField(ast, word, start, offset, parent, oop, results)
            end
        elseif isFuncArg(ast, offset) then
            checkProvideLocal(ast, word, start, results)
            checkFunctionArgByDocParam(ast, word, start, results)
        else
            local afterLocal = isAfterLocal(text, start)
            local stop = checkKeyWord(ast, text, start, offset, word, hasSpace, afterLocal, results)
            if stop then
                return
            end
            if not hasSpace then
                if afterLocal then
                    checkProvideLocal(ast, word, start, results)
                else
                    checkLocal(ast, word, start, results)
                    checkTableField(ast, word, start, results)
                    local env = guide.getENV(ast.ast, start)
                    checkGlobal(ast, word, start, offset, env, false, results)
                    checkModule(ast, word, start, results)
                end
            end
        end
        if not hasSpace then
            checkCommon(ast.uri, word, text, offset, results)
        end
    end
end

local function trySymbol(ast, text, offset, results)
    local symbol, start = lookBackward.findSymbol(text, offset)
    if not symbol then
        return nil
    end
    if isInString(ast, offset) then
        return nil
    end
    if symbol == '.'
    or symbol == ':' then
        local parent, oop = findParent(ast, text, start)
        if parent then
            tracy.ZoneBeginN 'completion.trySymbol'
            checkField(ast, '', start, offset, parent, oop, results)
            tracy.ZoneEnd()
        end
    end
    if symbol == '(' then
        checkFunctionArgByDocParam(ast, '', start, results)
    end
end

local function buildInsertDocFunction(doc)
    local args = {}
    for i, arg in ipairs(doc.args) do
        args[i] = ('${%d:%s}'):format(i, arg.name[1])
    end
    return ("\z
function (%s)\
\t$0\
end"):format(table.concat(args, ', '))
end

local function pushCallEnumsAndFuncs(defs)
    local results = {}
    for _, def in ipairs(defs) do
        if def.type == 'doc.type.enum'
        or def.type == 'doc.resume' then
            results[#results+1] = {
                label       = def[1],
                description = def.comment,
                kind        = define.CompletionItemKind.EnumMember,
            }
        end
        if def.type == 'doc.type.function' then
            results[#results+1] = {
                label       = infer.viewDocFunction(def),
                description = def.comment,
                kind        = define.CompletionItemKind.Function,
                insertText  = buildInsertDocFunction(def),
            }
        end
    end
    return results
end

local function getCallEnumsAndFuncs(source, index, oop)
    if source.type == 'function' and source.bindDocs then
        if not source.args then
            return
        end
        local arg
        if index <= #source.args then
            arg = source.args[index]
        else
            local lastArg = source.args[#source.args]
            if lastArg.type == '...' then
                arg = lastArg
            else
                return
            end
        end
        for _, doc in ipairs(source.bindDocs) do
            if  doc.type == 'doc.param'
            and doc.param[1] == arg[1] then
                return pushCallEnumsAndFuncs(vm.getDefs(doc.extends))
            elseif doc.type == 'doc.vararg'
            and    arg.type == '...' then
                return pushCallEnumsAndFuncs(vm.getDefs(doc.vararg))
            end
        end
    end
    if source.type == 'doc.type.function' then
        --[[
        always use literal index, that is:
        ```
        ---@class Class
        ---@field f(x: number, y: boolean)
        local c

        c.f(1, true) -- correct
        c:f(1, true) -- also correct
        ```
        --]]
        if oop then
            index = index - 1
        end
        local arg = source.args[index]
        if arg and arg.extends then
            return pushCallEnumsAndFuncs(vm.getDefs(arg.extends))
        end
    end
end

local function findCall(ast, text, offset)
    local call
    guide.eachSourceContain(ast.ast, offset, function (src)
        if src.type == 'call' then
            if not call or call.start < src.start then
                call = src
            end
        end
    end)
    return call
end

local function getCallArgInfo(call, text, offset)
    if not call.args then
        return 1, nil, nil
    end
    local oop = call.node.type == 'getmethod'
    for index, arg in ipairs(call.args) do
        if arg.start <= offset and arg.finish >= offset then
            return index, arg, oop
        end
    end
    return #call.args + 1, nil, oop
end

local function getFuncParamByCallIndex(func, index)
    if not func.args or #func.args == 0 then
        return nil
    end
    if index > #func.args then
        if func.args[#func.args].type == '...' then
            return func.args[#func.args]
        end
    end
    return func.args[index]
end

local function checkTableLiteralField(ast, text, offset, tbl, fields, results)
    local mark = {}
    for _, field in ipairs(tbl) do
        if field.type == 'tablefield'
        or field.type == 'tableindex'
        or field.type == 'tableexp' then
            local name = guide.getKeyName(field)
            if name then
                mark[name] = true
            end
        end
    end
    table.sort(fields, function (a, b)
        return guide.getKeyName(a) < guide.getKeyName(b)
    end)
    -- {$}
    local left = lookBackward.findWord(text, offset)
    if not left then
        local pos = lookBackward.findAnyPos(text, offset)
        local char = text:sub(pos, pos)
        if char == '{' or char == ',' or char == ';' then
            left = ''
        end
    end
    if left then
        for _, field in ipairs(fields) do
            local name = guide.getKeyName(field)
            if not mark[name] and matchKey(left, guide.getKeyName(field)) then
                results[#results+1] = {
                    label = guide.getKeyName(field),
                    kind  = define.CompletionItemKind.Property,
                    insertText = ('%s = $0'):format(guide.getKeyName(field)),
                    id    = stack(function ()
                        return {
                            detail      = buildDetail(field),
                            description = buildDesc(field),
                        }
                    end),
                }
            end
        end
    end
end

local function checkTableLiteralFieldByCall(ast, text, offset, call, defs, index, results)
    local source = findNearestTableField(ast, offset)
    if not source then
        return
    end
    if  source.type ~= 'table'
    and (not source.parent or source.parent.type ~= 'table') then
        return
    end
    local mark = {}
    local fields = {}
    local tbl = source
    if source.type ~= 'table' then
        tbl = source.parent
    end
    if tbl.parent ~= call.args then
        return
    end
    for _, def in ipairs(defs) do
        local func = searcher.getObjectValue(def) or def
        local param = getFuncParamByCallIndex(func, index)
        if not param then
            goto CONTINUE
        end
        local defs = vm.getDefs(param, '*')
        for _, field in ipairs(defs) do
            local name = guide.getKeyName(field)
            if name and not mark[name] then
                mark[name] = true
                fields[#fields+1] = field
            end
        end
        ::CONTINUE::
    end
    checkTableLiteralField(ast, text, offset, tbl, fields, results)
end

local function tryCallArg(ast, text, offset, results)
    local call = findCall(ast, text, offset)
    if not call then
        return
    end
    local myResults = {}
    local argIndex, arg, oop = getCallArgInfo(call, text, offset)
    if arg and arg.type == 'function' then
        return
    end
    local defs = vm.getDefs(call.node)
    for _, def in ipairs(defs) do
        def = searcher.getObjectValue(def) or def
        local enums = getCallEnumsAndFuncs(def, argIndex, oop)
        if enums then
            mergeEnums(myResults, enums, arg)
        end
    end
    for _, enum in ipairs(myResults) do
        results[#results+1] = enum
    end
    checkTableLiteralFieldByCall(ast, text, offset, call, defs, argIndex, results)
end

local function tryTable(ast, text, offset, results)
    offset = lookBackward.skipSpace(text, offset)
    local source = findNearestTableField(ast, offset)
    if not source then
        return
    end
    if  source.type ~= 'table'
    and (not source.parent or source.parent.type ~= 'table') then
        return
    end
    local mark = {}
    local fields = {}
    local tbl = source
    if source.type ~= 'table' then
        tbl = source.parent
    end
    local parent = tbl.parent
    local defs = vm.getDefs(parent, '*')
    for _, field in ipairs(defs) do
        local name = guide.getKeyName(field)
        if name and not mark[name] then
            mark[name] = true
            fields[#fields+1] = field
        end
    end
    checkTableLiteralField(ast, text, offset, tbl, fields, results)
end

local function getComment(ast, offset)
    for _, comm in ipairs(ast.comms) do
        if offset >= comm.start - 2 and offset <= comm.finish then
            return comm
        end
    end
    return nil
end

local function getLuaDoc(ast, offset)
    for _, doc in ipairs(ast.ast.docs) do
        if offset >= doc.start and offset <= doc.range then
            return doc
        end
    end
    return nil
end

local function tryLuaDocCate(word, results)
    for _, docType in ipairs {
        'class',
        'type',
        'alias',
        'param',
        'return',
        'field',
        'generic',
        'vararg',
        'overload',
        'deprecated',
        'meta',
        'version',
        'see',
        'diagnostic',
    } do
        if matchKey(word, docType) then
            results[#results+1] = {
                label       = docType,
                kind        = define.CompletionItemKind.Event,
            }
        end
    end
end

local function getLuaDocByContain(ast, offset)
    local result
    local range = math.huge
    guide.eachSourceContain(ast.ast.docs, offset, function (src)
        if not src.start then
            return
        end
        if  range  >= offset - src.start
        and offset <= src.finish then
            range = offset - src.start
            result = src
        end
    end)
    return result
end

local function getLuaDocByErr(ast, text, start, offset)
    local targetError
    for _, err in ipairs(ast.errs) do
        if  err.finish <= offset
        and err.start >= start  then
            if not text:sub(err.finish + 1, offset):find '%S' then
                targetError = err
                break
            end
        end
    end
    if not targetError then
        return nil
    end
    local targetDoc
    for i = #ast.ast.docs, 1, -1 do
        local doc = ast.ast.docs[i]
        if doc.finish <= targetError.start then
            targetDoc = doc
            break
        end
    end
    return targetError, targetDoc
end

local function tryLuaDocBySource(ast, offset, source, results)
    if source.type == 'doc.extends.name' then
        if source.parent.type == 'doc.class' then
            for _, doc in ipairs(vm.getDocDefines()) do
                if  doc.type == 'doc.class.name'
                and doc.parent ~= source.parent
                and matchKey(source[1], doc[1]) then
                    results[#results+1] = {
                        label       = doc[1],
                        kind        = define.CompletionItemKind.Class,
                        textEdit    = doc[1]:find '[^%w_]' and {
                            start   = source.start,
                            finish  = offset,
                            newText = doc[1],
                        },
                    }
                end
            end
        end
        return true
    elseif source.type == 'doc.type.name' then
        for _, doc in ipairs(vm.getDocDefines()) do
            if  (doc.type == 'doc.class.name' or doc.type == 'doc.alias.name')
            and doc.parent ~= source.parent
            and matchKey(source[1], doc[1]) then
                results[#results+1] = {
                    label       = doc[1],
                    kind        = define.CompletionItemKind.Class,
                    textEdit    = doc[1]:find '[^%w_]' and {
                        start   = source.start,
                        finish  = offset,
                        newText = doc[1],
                    },
                }
            end
        end
        return true
    elseif source.type == 'doc.param.name' then
        local funcs = {}
        guide.eachSourceBetween(ast.ast, offset, math.huge, function (src)
            if src.type == 'function' and src.start > offset then
                funcs[#funcs+1] = src
            end
        end)
        table.sort(funcs, function (a, b)
            return a.start < b.start
        end)
        local func = funcs[1]
        if not func or not func.args then
            return
        end
        for _, arg in ipairs(func.args) do
            if arg[1] and matchKey(source[1], arg[1]) then
                results[#results+1] = {
                    label  = arg[1],
                    kind   = define.CompletionItemKind.Interface,
                }
            end
        end
        return true
    elseif source.type == 'doc.diagnostic' then
        for _, mode in ipairs(DiagnosticModes) do
            if matchKey(source.mode, mode) then
                results[#results+1] = {
                    label    = mode,
                    kind     = define.CompletionItemKind.Enum,
                    textEdit = {
                        start   = source.start,
                        finish  = source.start + #source.mode - 1,
                        newText = mode,
                    },
                }
            end
        end
        return true
    elseif source.type == 'doc.diagnostic.name' then
        for name in pairs(define.DiagnosticDefaultSeverity) do
            if matchKey(source[1], name) then
                results[#results+1] = {
                    label = name,
                    kind  = define.CompletionItemKind.Value,
                    textEdit = {
                        start   = source.start,
                        finish  = source.start + #source[1] - 1,
                        newText = name,
                    },
                }
            end
        end
    end
    return false
end

local function tryLuaDocByErr(ast, offset, err, docState, results)
    if err.type == 'LUADOC_MISS_CLASS_EXTENDS_NAME' then
        for _, doc in ipairs(vm.getDocDefines()) do
            if  doc.type == 'doc.class.name'
            and doc.parent ~= docState then
                results[#results+1] = {
                    label       = doc[1],
                    kind        = define.CompletionItemKind.Class,
                }
            end
        end
    elseif err.type == 'LUADOC_MISS_TYPE_NAME' then
        for _, doc in ipairs(vm.getDocDefines()) do
            if  (doc.type == 'doc.class.name' or doc.type == 'doc.alias.name') then
                results[#results+1] = {
                    label       = doc[1],
                    kind        = define.CompletionItemKind.Class,
                }
            end
        end
    elseif err.type == 'LUADOC_MISS_PARAM_NAME' then
        local funcs = {}
        guide.eachSourceBetween(ast.ast, offset, math.huge, function (src)
            if src.type == 'function' and src.start > offset then
                funcs[#funcs+1] = src
            end
        end)
        table.sort(funcs, function (a, b)
            return a.start < b.start
        end)
        local func = funcs[1]
        if not func or not func.args then
            return
        end
        local label = {}
        local insertText = {}
        for i, arg in ipairs(func.args) do
            if arg[1] and not arg.dummy then
                label[#label+1] = arg[1]
                if #label == 1 then
                    insertText[#insertText+1] = ('%s ${%d:any}'):format(arg[1], #label)
                else
                    insertText[#insertText+1] = ('---@param %s ${%d:any}'):format(arg[1], #label)
                end
            end
        end
        results[#results+1] = {
            label            = table.concat(label, ', '),
            kind             = define.CompletionItemKind.Snippet,
            insertTextFormat = 2,
            insertText       = table.concat(insertText, '\n'),
        }
        for i, arg in ipairs(func.args) do
            if arg[1] then
                results[#results+1] = {
                    label  = arg[1],
                    kind   = define.CompletionItemKind.Interface,
                }
            end
        end
    elseif err.type == 'LUADOC_MISS_DIAG_MODE' then
        for _, mode in ipairs(DiagnosticModes) do
            results[#results+1] = {
                label = mode,
                kind  = define.CompletionItemKind.Enum,
            }
        end
    elseif err.type == 'LUADOC_MISS_DIAG_NAME' then
        for name in pairs(define.DiagnosticDefaultSeverity) do
            results[#results+1] = {
                label = name,
                kind  = define.CompletionItemKind.Value,
            }
        end
    end
end

local function buildLuaDocOfFunction(func)
    local index = 1
    local buf = {}
    buf[#buf+1] = '${1:comment}'
    local args = {}
    local returns = {}
    if func.args then
        for _, arg in ipairs(func.args) do
            args[#args+1] = infer.searchAndViewInfers(arg)
        end
    end
    if func.returns then
        for _, rtns in ipairs(func.returns) do
            for n = 1, #rtns do
                if not returns[n] then
                    returns[n] = infer.searchAndViewInfers(rtns[n])
                end
            end
        end
    end
    for n, arg in ipairs(args) do
        local funcArg = func.args[n]
        if funcArg[1] and not funcArg.dummy then
            index = index + 1
            buf[#buf+1] = ('---@param %s ${%d:%s}'):format(
                funcArg[1],
                index,
                arg
            )
        end
    end
    for _, rtn in ipairs(returns) do
        index = index + 1
        buf[#buf+1] = ('---@return ${%d:%s}'):format(
            index,
            rtn
        )
    end
    local insertText = table.concat(buf, '\n')
    return insertText
end

local function tryLuaDocOfFunction(doc, results)
    if not doc.bindSources then
        return
    end
    local func
    for _, source in ipairs(doc.bindSources) do
        if source.type == 'function' then
            func = source
            break
        end
    end
    if not func then
        return
    end
    for _, otherDoc in ipairs(doc.bindGroup) do
        if otherDoc.type == 'doc.param'
        or otherDoc.type == 'doc.return' then
            return
        end
    end
    local insertText = buildLuaDocOfFunction(func)
    results[#results+1] = {
        label   = '@param;@return',
        kind    = define.CompletionItemKind.Snippet,
        insertTextFormat = 2,
        filterText   = '---',
        insertText   = insertText
    }
end

local function tryLuaDoc(ast, text, offset, results)
    local doc = getLuaDoc(ast, offset)
    if not doc then
        return
    end
    if doc.type == 'doc.comment' then
        local line = text:sub(doc.start, doc.range)
        -- 尝试 ---$
        if line == '-' then
            tryLuaDocOfFunction(doc, results)
            return
        end
        -- 尝试 ---@$
        local cate = line:match('^-%s*@(%a*)$')
        if cate then
            tryLuaDocCate(cate, results)
            return
        end
    end
    -- 根据输入中的source来补全
    local source = getLuaDocByContain(ast, offset)
    if source then
        local suc = tryLuaDocBySource(ast, offset, source, results)
        if suc then
            return
        end
    end
    -- 根据附近的错误消息来补全
    local err, expectDoc = getLuaDocByErr(ast, text, doc.start, offset)
    if err then
        tryLuaDocByErr(ast, offset, err, expectDoc, results)
        return
    end
end

local function tryComment(ast, text, offset, results)
    if #results > 0 then
        return
    end
    local word = lookBackward.findWord(text, offset)
    local doc  = getLuaDoc(ast, offset)
    if not word then
        local comment = getComment(ast, offset)
        if comment.type == 'comment.short'
        or comment.type == 'comment.cshort' then
            if comment.text == '' then
                results[#results+1] = {
                    label = '#region',
                    kind  = define.CompletionItemKind.Snippet,
                }
                results[#results+1] = {
                    label = '#endregion',
                    kind  = define.CompletionItemKind.Snippet,
                }
            end
        end
        return
    end
    if doc and doc.type ~= 'doc.comment' then
        return
    end
    checkCommon(ast.uri, word, text, offset, results)
end

local function makeCache(uri, offset, results)
    local cache = workspace.getCache 'completion'
    if not uri then
        cache.results = nil
        return
    end
    local text  = files.getText(uri)
    local word = lookBackward.findWord(text, offset)
    if not word or #word < 2 then
        cache.results = nil
        return
    end
    cache.results = results
    cache.offset  = offset
    cache.word    = word:lower()
    cache.length  = #word
end

local function getCache(uri, offset)
    local cache = workspace.getCache 'completion'
    if not cache.results then
        return nil
    end
    local text  = files.getText(uri)
    local word = lookBackward.findWord(text, offset)
    if not word then
        return nil
    end
    if word:sub(1, #cache.word):lower() ~= cache.word then
        return nil
    end

    local ext = #word - cache.length
    cache.length = #word
    for _, result in ipairs(cache.results) do
        if result.textEdit then
            result.textEdit.finish = result.textEdit.finish + ext
        end
    end

    if cache.results.enableCommon then
        local results = cache.results
        for i = #results, 1, -1 do
            local res = results[i]
            if res.kind == define.CompletionItemKind.Text then
                results[i] = results[#results]
                results[#results] = nil
            end
        end
        checkCommon(nil, word, text, offset, results)
    end

    return cache.results
end

local function clearCache()
    local cache = workspace.getCache 'completion'
    cache.results = nil
end

local function completion(uri, offset, triggerCharacter)
    tracy.ZoneBeginN 'completion cache'
    local results = getCache(uri, offset)
    tracy.ZoneEnd()
    if results then
        return results
    end
    tracy.ZoneBeginN 'completion #1'
    local ast = files.getState(uri)
    local text = files.getText(uri)
    results = {}
    clearStack()
    tracy.ZoneEnd()
    tracy.ZoneBeginN 'completion #2'
    if ast then
        if getComment(ast, offset) then
            tryLuaDoc(ast, text, offset, results)
            tryComment(ast, text, offset, results)
        else
            trySpecial(ast, text, offset, results)
            tryCallArg(ast, text, offset, results)
            tryTable(ast, text, offset, results)
            tryWord(ast, text, offset, triggerCharacter, results)
            tryIndex(ast, text, offset, results)
            trySymbol(ast, text, offset, results)
        end
    else
        local word = lookBackward.findWord(text, offset)
        if word then
            checkCommon(nil, word, text, offset, results)
        end
    end
    tracy.ZoneEnd()

    if #results == 0 then
        clearCache()
        return nil
    end

    tracy.ZoneBeginN 'completion #3'
    makeCache(uri, offset, results)
    tracy.ZoneEnd()
    return results
end

local function resolve(id)
    local item = resolveStack(id)
    local cache = workspace.getCache 'completion'
    if item and cache.results then
        for _, res in ipairs(cache.results) do
            if res and res.id == id then
                for k, v in pairs(item) do
                    res[k] = v
                end
                res.id = nil
                break
            end
        end
    end
    return item
end

return {
    completion   = completion,
    resolve      = resolve,
    clearCache   = clearCache,
}
