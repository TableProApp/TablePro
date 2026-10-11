import json
import uno

local = uno.getComponentContext()
resolver = local.ServiceManager.createInstanceWithContext(
    "com.sun.star.bridge.UnoUrlResolver", local
)
context = resolver.resolve(
    "uno:socket,host=127.0.0.1,port=2010;urp;StarOffice.ComponentContext"
)
desktop = context.ServiceManager.createInstanceWithContext(
    "com.sun.star.frame.Desktop", context
)
document = desktop.getCurrentComponent()
sheet = document.Sheets.getByIndex(0)
cells = []
for row in range(8):
    cell = sheet.getCellByPosition(0, row)
    cells.append(
        {
            "row": row + 1,
            "string": cell.getString(),
            "formula": cell.getFormula(),
            "type": str(cell.getType()).split("('")[-1].rstrip("')>"),
        }
    )
print(json.dumps(cells, ensure_ascii=False, indent=2))
