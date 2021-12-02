include Re.Pcre

let with_pat fn ?rex ?pat =
  let rex =
    match (pat, rex) with
      | Some p, _ -> regexp p
      | None, Some r -> r
      | None, None -> assert false
  in
  fn ~rex

let exec = with_pat exec
let split = with_pat split
let substitute = with_pat substitute
let pmatch = with_pat pmatch
let regexp_or l = regexp (String.concat "|" l)
