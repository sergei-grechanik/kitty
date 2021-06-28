for i in range(0, 100)
    let higroup_name = "TerminalImageLine" . string(i)
    execute "hi " . higroup_name . " ctermfg=" . string(i)
    let prop_name = "TerminalImageLine" . string(i)
    if !empty(prop_type_get(prop_name))
        call prop_type_delete(prop_name)
    endif
    call prop_type_add(prop_name, {'highlight': higroup_name})
endfor

let s:path = fnamemodify(resolve(expand('<sfile>:p')), ':h')

function! UploadTerminalImage(filename, cols, rows) abort
    let cols_str = shellescape(string(a:cols))
    let rows_str = shellescape(string(a:rows))
    let filename_expanded = resolve(expand(a:filename))
    let filename_str = shellescape(filename_expanded)
    let tmpfile = tempname()
    call system(s:path . "/test-img.sh" .
                \ " -c " . cols_str .
                \ " -r " . rows_str .
                \ " -e " . shellescape(tmpfile) .
                \ " -o " . shellescape(tmpfile) .
                \ " --noesc " .
                \ " " . filename_str .
                \ " < /dev/tty > /dev/tty")
    let lines = readfile(tmpfile)
    let result = []
    let i = 0
    for line in lines
        let prop_type = "TerminalImageLine" . string(i)
        call add(result,
                 \ {'text': line, 'props': [{'col': 1, 'length': len(line), 'type': prop_type}]})
        let i += 1
    endfor
    call delete(tmpfile)
    return result
endfun
