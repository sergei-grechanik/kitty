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

let g:terminal_image_min_columns=1
let g:terminal_image_min_rows=1
let g:terminal_image_max_columns=100
let g:terminal_image_max_rows=30
let g:terminal_image_columns_per_inch=6.0
let g:terminal_image_rows_per_inch=3.0

function! ComputeBestImageSize(filename)
    let maxcols = min([g:terminal_image_max_columns, &columns, winwidth(0) - 6])
    let maxrows = min([g:terminal_image_max_rows, &lines, winheight(0) - 2])
    let maxcols = max([g:terminal_image_min_columns, maxcols])
    let maxrows = max([g:terminal_image_min_rows, maxrows])
    let filename_expanded = resolve(expand(a:filename))
    let filename_str = shellescape(filename_expanded)
    let res = system("identify -format '%w %h %x %y' " . filename_str)
    if res == ""
        return [maxcols, maxrows]
    endif
    let whxy = split(res, ' ')
    let w = str2float(whxy[0])/str2float(whxy[2])
    let h = str2float(whxy[1])/str2float(whxy[3])
    let w = w * g:terminal_image_columns_per_inch
    let h = h * g:terminal_image_rows_per_inch
    if w > maxcols
        let h = h * maxcols / w
        let w = maxcols
    endif
    if h > maxrows
        let w = w * maxrows / h
        let h = maxrows
    endif
    return [max([g:terminal_image_min_columns, float2nr(w)]),
           \ max([g:terminal_image_min_rows, float2nr(h)])]
endfun

function! UploadTerminalImage(filename, cols, rows)
    let cols = a:cols
    let rows = a:rows
    if cols == 0 || rows == 0
        let dims = ComputeBestImageSize(a:filename)
        let cols = dims[0]
        let rows = dims[1]
    endif
    let cols_str = shellescape(string(cols))
    let rows_str = shellescape(string(rows))
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
    if v:shell_error != 0
        if filereadable(tmpfile)
            let err_message = readfile(tmpfile)[0]
            call delete(tmpfile)
            throw "Uploading error: " . err_message
        endif
        throw "Unknown uploading error"
    endif
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

function! ShowImageUnderCursor() abort
    let cfile = expand('<cfile>')
    let filenames = [cfile, expand('%:p:h') . "/" . cfile]
    if exists('b:netrw_curdir')
        call add(filenames, b:netrw_curdir . "/" . cfile)
    endif
    let globlist = glob(expand('%:p:h') . "/**/" . cfile, 0, 1)
    if len(globlist) == 1
        call extend(filenames, globlist)
    endif
    for filename in filenames
        if filereadable(filename)
            let uploading_message = popup_atcursor("Uploading " . filename, {})
            redraw
            echo "Uploading " . filename
            try
                let text = UploadTerminalImage(filename, 0, 0)
                redraw
                echo "Showing " . filename
            catch
                call popup_clear(uploading_message)
                " Vim doesn't want to redraw unless I put echo in between
                redraw!
                echo
                redraw!
                echohl ErrorMsg
                echo v:exception
                echohl None
                return
            endtry
            call popup_clear(uploading_message)
            return popup_atcursor(text, {})
        endif
    endfor
    echom "Image not readable: " . string(filenames)
endfun
