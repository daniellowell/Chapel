#include "insertIndexType.h"
#include "expr.h"
#include "stmt.h"
#include "symbol.h"
#include "type.h"
#include "symtab.h"
#include "stringutil.h"
#include "view.h"

void InsertIndexType::preProcessStmt(Stmt* stmt) {
  currentStmt = stmt;
  if (DefStmt* def_stmt = dynamic_cast<DefStmt*>(stmt)) {
    if (Symbol* sym = def_stmt->typeDef()) {
      currentScope = sym->parentScope;
    }
    else if (Symbol* sym = def_stmt->varDef()) {
      currentScope = sym->parentScope;
    } else {
      currentScope = NULL;
    }
  }
  else {
    currentScope = NULL;
  }
}


void InsertIndexType::preProcessType(Type* type) {
  if (!currentScope || !currentStmt) {
    return;
  }

  DomainType* domain_type = dynamic_cast<DomainType*>(type);

  if (!domain_type) {
    return;
  }
  
	//this should be the initialization expression: numdims, class reference, etc.
  //char* name = glomstrings(3, "_index_", intstring(domain_type->numdims));
  char* name = glomstrings(2, "_index_", domain_type->symbol->name);
  
  IndexType* index_type = dynamic_cast<IndexType*>(domain_type->idxType);
  if (!index_type){
  	return;
  }
  
  Symbol* index_sym = Symboltable::lookupInScope(name, commonModule->modScope);
  if (index_sym) {
    type = index_sym->type;
  }
  else {
	  SymScope* saveScope = Symboltable::setCurrentScope(commonModule->modScope);
  	TypeSymbol* index_sym = new TypeSymbol(name, index_type);
  	index_type->addSymbol(index_sym);
  	DefStmt* def_stmt = new DefStmt(new DefExpr(index_sym));
  	index_sym->setDefPoint(def_stmt->defExprList);
  	domain_type->idxType = index_type;
		commonModule->stmts->insertBefore(def_stmt);
  	Symboltable::setCurrentScope(saveScope);
	}
}


void InsertIndexType::postProcessStmt(Stmt* stmt) {
  currentStmt = NULL;
  currentScope = NULL;
}
