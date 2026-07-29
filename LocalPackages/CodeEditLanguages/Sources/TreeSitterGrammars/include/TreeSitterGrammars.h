#ifndef TreeSitterGrammars_h
#define TreeSitterGrammars_h

typedef struct TSLanguage TSLanguage;

const TSLanguage *tree_sitter_sql(void);
const TSLanguage *tree_sitter_bash(void);
const TSLanguage *tree_sitter_javascript(void);
const TSLanguage *tree_sitter_json(void);

#endif /* TreeSitterGrammars_h */
